const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Exercise the shipped source against Amethyst's bootstrap/extension/allocator
// protocol, with debugger transport substituted. This does not test a device.
// Protocol reference: Amethyst-iOS-MyRemastered commit 70b8bea, utils.m and
// UniversalJIT26Extension.js. The initial 0x69 sentinel is a protocol probe.
const extension = `
let finishMapping = false;
commands[3] = function() { finishMapping = x0 != 0; };
legacyCommands[0x69] = function() {
    x1 = x0; x0 = 0;
    JIT26PrepareRegion();
    if (finishMapping) JIT26Detach();
};
`;
const extensionBytes = Buffer.from(extension);
const littleEndian = value => {
    const bytes = Buffer.alloc(8);
    bytes.writeBigUInt64LE(BigInt(value));
    return bytes.toString('hex');
};
const instruction = immediate => {
    const bytes = Buffer.alloc(4);
    bytes.writeUInt32LE((0xd4200000 | (immediate << 5)) >>> 0);
    return bytes.toString('hex');
};

function run(source, options = {}) {
    const stops = [
        { pc: 0x1000n, x0: 0x4000n, x1: 0n, x16: 0n },
        { pc: 0x1100n, x0: 0x2000n, x1: BigInt(extensionBytes.length), x16: 2n },
        { pc: 0x1200n, x0: 1n, x1: 0n, x16: 3n },
        { pc: 0x1300n, x0: 0x4000n, x1: 0n, x16: 0n }
    ];
    if (options.signalStop) stops.unshift({ pc: 0x9000n, x0: 0n, x1: 0n, x16: 0n });
    const reads = new Map([
        ['1000', instruction(0x69)], ['1100', instruction(0xf00d)],
        ['1200', instruction(0xf00d)], ['1300', instruction(0x69)], ['9000', '1f2003d5']
    ]);
    const commands = [];
    const prepared = [];
    let currentStop;
    let didProbe = false;
    let didDetach = false;
    const registers = () => ({ '00': currentStop.x0, '01': currentStop.x1,
                                '10': currentStop.x16, '20': currentStop.pc });
    const nextStop = () => {
        assert(stops.length > 0, 'The script continued beyond the final allocator stop');
        currentStop = stops.shift();
        if (options.noThread) return 'T05';
        const fields = options.omitRegisters ? '' : Object.entries(registers())
            .map(([key, value]) => `${key}:${littleEndian(value)};`).join('');
        return options.threadLast ? `T05${fields}thread:1;` : `T05thread:1;${fields}`;
    };
    const context = vm.createContext({
        get_pid: () => 123,
        log: () => {},
        prepare_memory_region: (address, length) => {
            prepared.push([BigInt(address), BigInt(length)]);
            return 'OK';
        },
        send_command: command => {
            commands.push(command);
            assert(commands.length < 100, 'Unbounded debugger command loop');
            if (command === 'vAttach;7b') return 'T05thread:1;';
            if (command === 'c' || command === 'vCont;S05:1') return nextStop();
            if (command.startsWith('P20=')) return 'OK';
            if (command === 'P0=E0000069;thread:1;') { didProbe = true; return 'OK'; }
            if (command.startsWith('P0=')) {
                assert.equal(command, `P0=${littleEndian(0x400000000n)};thread:1;`);
                return 'OK';
            }
            if (command === '_M4000,rx') return '400000000';
            if (command === 'D') { didDetach = true; return 'OK'; }
            const registerRead = /^p([0-9a-f]+);thread:1;$/.exec(command);
            if (registerRead) {
                const key = registerRead[1].padStart(2, '0');
                return options.invalidRegister ? 'unavailable' : littleEndian(registers()[key]);
            }
            const memoryRead = /^m([0-9a-f]+),([0-9a-f]+)$/.exec(command);
            if (memoryRead) {
                if (memoryRead[1] === '2000') {
                    assert.equal(memoryRead[2], extensionBytes.length.toString(16),
                                 'The injected script length must use RSP hexadecimal encoding');
                    return options.invalidExtension ? Buffer.from('throw new Error("bad extension")').toString('hex') : extensionBytes.toString('hex');
                }
                assert.equal(memoryRead[2], '4');
                assert(reads.has(memoryRead[1]), `Unexpected instruction address: ${memoryRead[1]}`);
                return reads.get(memoryRead[1]);
            }
            throw new Error(`Unexpected command: ${command}`);
        }
    });
    const evaluate = () => vm.runInContext(source, context, { timeout: 1000 });
    if (options.expectedError) {
        assert.throws(evaluate, options.expectedError);
        assert.equal(didDetach, false, 'Native cleanup, not script success, must handle the failed evaluation');
        return;
    }
    evaluate();
    assert(didProbe, 'The initial Amethyst Universal JIT probe was skipped');
    assert(didDetach, 'The allocator did not explicitly detach');
    assert.deepEqual(prepared, [[0x400000000n, 0x4000n]]);
    assert.equal(stops.length, 0, 'Not all protocol requests were handled');
    if (options.omitRegisters) assert(commands.some(value => value.startsWith('p20;')));
    if (options.signalStop) assert(commands.includes('vCont;S05:1'));
}

let count = 0;
for (const file of process.argv.slice(2)) {
    const source = fs.readFileSync(file, 'utf8');
    for (const options of [
        {}, { threadLast: true }, { omitRegisters: true },
        { signalStop: true }, { signalStop: true, threadLast: true },
        { noThread: true, expectedError: /did not identify a thread/ },
        { omitRegisters: true, invalidRegister: true, expectedError: /did not return register/ },
        { invalidExtension: true, expectedError: /JIT script extension failed: bad extension/ }
    ]) { run(source, options); count++; }
}
assert(count > 0, 'Provide the script resource paths');
console.log(`${count} Universal JIT protocol tests passed`);
