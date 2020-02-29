const x86 = @import("machine.zig");
const std = @import("std");

const assert = std.debug.assert;

usingnamespace(@import("types.zig"));

const AvxOpcode = x86.avx.AvxOpcode;

const Mnemonic = x86.Mnemonic;
const Instruction = x86.Instruction;
const Machine = x86.Machine;
const Operand = x86.operand.Operand;
const Immediate = x86.Immediate;
const OperandType = x86.operand.OperandType;

pub const Signature = struct {
    operands: [4]OperandType,

    pub fn ops(
        o1: OperandType,
        o2: OperandType,
        o3: OperandType,
        o4: OperandType
    ) Signature {
        return Signature {
            .operands = [4]OperandType { o1, o2, o3, o4 },
        };
    }

    pub fn ops0() Signature {
        return Signature {
            .operands = [4]OperandType { .none, .none, .none, .none },
        };
    }

    pub fn ops1(o1: OperandType) Signature {
        return Signature {
            .operands = [4]OperandType { o1, .none, .none, .none },
        };
    }

    pub fn ops2(o1: OperandType, o2: OperandType) Signature {
        return Signature {
            .operands = [4]OperandType { o1, o2, .none, .none },
        };
    }

    pub fn ops3(o1: OperandType, o2: OperandType, o3: OperandType) Signature {
        return Signature {
            .operands = [4]OperandType { o1, o2, o3, .none },
        };
    }

    pub fn ops4(o1: OperandType, o2: OperandType, o3: OperandType, o4: OperandType) Signature {
        return Signature {
            .operands = [4]OperandType { o1, o2, o3, o4 },
        };
    }

    pub fn fromOperands(
        operand1: ?*const Operand,
        operand2: ?*const Operand,
        operand3: ?*const Operand,
        operand4: ?*const Operand
    ) Signature {
        const o1 = if (operand1) |op| op.operandType() else OperandType.none;
        const o2 = if (operand2) |op| op.operandType() else OperandType.none;
        const o3 = if (operand3) |op| op.operandType() else OperandType.none;
        const o4 = if (operand4) |op| op.operandType() else OperandType.none;
        return Signature {
            .operands = [4]OperandType { o1, o2, o3, o4 },
        };
    }

    pub fn debugPrint(self: Signature) void {
        std.debug.warn("(", .{});
        for (self.operands) |operand| {
            if (operand == .none) {
                continue;
            }
            std.debug.warn("{},", .{@tagName(operand)});
        }
        std.debug.warn("): ", .{});
    }

    pub fn matchTemplate(template: Signature, instance: Signature) bool {
        for (template.operands) |templ, i| {
            const rhs = instance.operands[i];
            if (templ == .none and rhs == .none) {
                continue;
            } else if (!OperandType.matchTemplate(templ, rhs)) {
                return false;
            }

        }
        return true;
    }
};

/// Special opcode edge cases
/// Some opcode/instruction combinations have special legacy edge cases we need
/// to check before we can confirm a match.
pub const OpcodeEdgeCase = enum {
    None = 0x0,

    /// Prior to x86-64, the instructions:
    ///     90      XCHG EAX, EAX
    /// and
    ///     90      NOP
    /// were encoded the same way and might be treated specially by the CPU.
    /// However, on x86-64 `XCHG EAX,EAX` is no longer a NOP because it zeros
    /// the upper 32 bits of the RAX register.
    ///
    /// When AMD designed x86-64 they decide 90 should still be treated as a NOP.
    /// This means we have to choose a different encoding on x86-64.
    XCHG_EAX = 0x1,

    /// sign-extended immediate value (ie this opcode sign extends)
    Sign,

    /// mark an encoding that will only work if the immediate doesn't need a
    /// sign extension (ie this opcode zero extends)
    ///
    /// eg: `MOV r64, imm32` can be encode in the same way as `MOV r32, imm32`
    /// as long as the immediate is non-negative since all operations on 32 bit
    /// registers implicitly zero extend
    NoSign,

    /// Not encodable on 64 bit mode
    No64,

    /// Not encodable on 32/16 bit mode
    No32,

    /// Valid encoding, but undefined behaviour
    Undefined,

    pub fn isEdgeCase(
        self: OpcodeEdgeCase,
        item: InstructionItem,
        mode: Mode86,
        op1: ?*const Operand,
        op2: ?*const Operand,
        op3: ?*const Operand,
        op4: ?*const Operand
    ) bool {
        switch (self) {
            .XCHG_EAX => {
                return (mode == .x64 and op1.?.Reg == .EAX and op2.?.Reg == .EAX);
            },
            .NoSign, .Sign => {
                const sign = self;

                var imm_pos: u2 = undefined;
                // figure out which operand is the immediate
                if (op1 != null and op1.?.tag() == .Imm) {
                    imm_pos = 0;
                } else if (op2 != null and op2.?.tag() == .Imm) {
                    imm_pos = 1;
                } else if (op3 != null and op3.?.tag() == .Imm) {
                    imm_pos = 2;
                } else if (op4 != null and op4.?.tag() == .Imm) {
                    imm_pos = 3;
                } else {
                    unreachable;
                }
                const imm = switch (imm_pos) {
                    0 => op1.?.Imm,
                    1 => op2.?.Imm,
                    2 => op3.?.Imm,
                    3 => op4.?.Imm,
                };
                switch (sign) {
                    // Matches edgecase when it's an unsigned immediate that will get sign extended
                    .Sign => {
                        const is_unsigned = imm.sign == .Unsigned;
                        return (is_unsigned and imm.willSignExtend(item.signature.operands[imm_pos]));
                    },
                    // Matches edgecase when it's a signed immedate that needs its sign extended
                    .NoSign => {
                        const is_signed = imm.sign == .Signed;
                        return (is_signed and imm.isNegative());
                    },
                    else => unreachable,
                }
            },
            .No64 => unreachable,
            .No32 => unreachable,
            .Undefined => unreachable,

            .None => return false,
        }
    }
};



// Quick refrences:
//
// * https://en.wikichip.org/wiki/intel/cpuid
// * https://en.wikipedia.org/wiki/X86_instruction_listings
// * https://www.felixcloutier.com/x86/
pub const CpuVersion = enum {
    /// Added in 8086 / 8088
    _8086,
    /// Added in 80186 / 80188
    _186,
    /// Added in 80286
    _286,
    /// Added in 80386
    _386,
    /// Added in 80486 models
    _486,
    /// Added in later 80486 models
    _486p,
    /// Added in 8087 FPU
    _087,
    /// Added in 80287 FPU
    _287,
    /// Added in 80387 FPU
    _387,
    /// Added in Pentium
    Pent,
    /// Added in Pentium MMX
    MMX,
    /// Added in AMD K6
    K6,
    /// Added in Pentium Pro
    PentPro,
    /// Added in Pentium II
    Pent2,
    /// Added in SSE
    SSE,
    /// Added in SSE2
    SSE2,
    /// Added in SSE3
    SSE3,
    /// Added in SSSE3 (supplemental SSE3)
    SSSE3,
    /// Added in SSE4a
    SSE4_a,
    /// Added in SSE4.1
    SSE4_1,
    /// Added in SSE4.2
    SSE4_2,
    /// Added in x86-64
    x64,
    /// Added in AMD-V
    AMD_V,
    /// Added in Intel VT-x
    VT_x,
    /// CPUID.01H.EAX[11:8] = Family = 6 or 15 = 0110B or 1111B
    P6,
    /// Added in ABM (advanced bit manipulation)
    ABM,
    /// Added in BMI1 (bit manipulation instructions 1)
    BMI1,
    /// Added in BMI2 (bit manipulation instructions 2)
    BMI2,
    /// Added in TBM (trailing bit manipulation)
    TBM,
    /// PKRU (Protection Key Rights Register for user pages)
    PKRU,
    /// Added in AVX
    AVX,
    /// Added in AVX2
    AVX2,
    /// Added in AVX-512 F (Foundation)
    AVX512F,
    /// Added in AVX-512 CD (Conflict Detection)
    AVX512CD,
    /// Added in AVX-512 ER (Exponential and Reciprocal)
    AVX512ER,
    /// Added in AVX-512 PF (Prefetch Instructions)
    AVX512PF,
    /// Added in AVX-512 VL (Vector length extensions)
    AVX512VL,
    /// Added in AVX-512 BW (Byte and Word)
    AVX512BW,
    /// Added in AVX-512 DQ (Doubleword and Quadword)
    AVX512DQ,
    /// Added in AVX-512 IFMA (Integer Fused Multiply Add)
    AVX512_IFMA,
    /// Added in AVX-512 VBMI (Vector Byte Manipulation Instructions)
    AVX512_VBMI,
    /// Added in AVX-512 4VNNIW (Vector Neural Network Instructions Word variable precision (4VNNIW))
    AVX512_4VNNIW,
    /// Added in AVX-512 4FMAPS (Fused Multiply Accumulation Packed Single precision (4FMAPS))
    AVX512_4FMAPS,
    /// Added in AVX-512 VPOPCNTDQ (Vector Population Count)
    AVX512_VPOPCNTDQ,
    /// Added in AVX-512 VNNI (Vector Neural Network Instructions)
    AVX512_VNNI,
    /// Added in AVX-512 VBMI2 (Vector Byte Manipulation Instructions 2)
    AVX512_VMBI2,
    /// Added in AVX-512 BITALG (Bit Algorithms)
    AVX512_BITALG,
    /// Added in AVX-512 VP2INTERSECT (Vector Pair Intersection to a Pair of Mask Registers)
    AVX512_VP2INTERSECT,
    /// Added in AVX-512 GFNI (Galois field new instructions EVEX version)
    AVX512_GFNI,
    /// Added in AVX-512 VPCLMULQDQ (Carry-less multiplication quadword EVEX version)
    AVX512_VPCLMULQDQ,

    /// CPUID flag ADX
    ADX,
    /// CPUID flag AES
    AES,
    /// CPUID flag CLDEMOTE
    CLDEMOTE,
    /// CPUID flag CLFLUSHOPT
    CLFLUSHOPT,
    /// CPUID flag CET_IBT (Control-flow Enforcement Technology - Indirect-Branch Tracking)
    CET_IBT,
    /// CPUID flag CET_SS (Control-flow Enforcement Technology - Shadow Stack)
    CET_SS,
    /// CPUID flag CLWB
    CLWB,
    /// CPUID flag FMA (Fused Multiply and Add)
    FMA,
    /// CPUID flag FSGSBASE
    FSGSBASE,
    /// CPUID flag FXSR
    FXSR,
    /// CPUID flag F16C
    F16C,
    /// CPUID flag SGX (Software Guard eXtensions)
    SGX,
    /// CPUID flag SMX (Safer Mode eXtensions)
    SMX,
    /// CPUID flag GFNI
    GFNI,
    /// CPUID flag HLE
    HLE,
    /// CPUID flag INVPCID
    INVPCID,
    /// CPUID flag MOVBE
    MOVBE,
    /// CPUID flag MOVDIRI
    MOVDIRI,
    /// CPUID flag MOVDIR64B
    MOVDIR64B,
    /// CPUID flag MPX (memory protection extension)
    MPX,
    /// CPUID flag OSPKE
    OSPKE,
    /// CPUID flag PCLMULQDQ
    PCLMULQDQ,
    /// CPUID flag PREFETCHW
    PREFETCHW,
    /// CPUID flag PTWRITE
    PTWRITE,
    /// CPUID flag RDPID
    RDPID,
    /// CPUID flag RDRAND
    RDRAND,
    /// CPUID flag RDSEED
    RDSEED,
    /// CPUID flag RTM
    RTM,
    /// CPUID flag SHA
    SHA,
    /// CPUID flag SMAP
    SMAP,
    /// CPUID flag HLE or RTM
    TDX,
    /// CPUID flag WAITPKG
    WAITPKG,
    /// CPUID flag VAES
    VAES,
    /// CPUID flag VPCLMULQDQ
    VPCLMULQDQ,
    /// CPUID flag XSAVE
    XSAVE,
    /// CPUID flag XSAVEC
    XSAVEC,
    /// CPUID flag XSAVEOPT
    XSAVEOPT,
    /// CPUID flag XSS
    XSS,

    /// LAHF valid in 64 bit mode only if CPUID.80000001H:ECX.LAHF-SAHF[bit 0]
    FeatLAHF,
};

pub const InstructionPrefix = enum {
    Lock,
    Repne,
    Rep,
    Bnd,
};

pub const InstructionEncoding = enum {
    ZO,     // no operands
    ZO16,   // no operands, 16 bit void operand
    ZO32,   // no operands, 32 bit void operand
    ZO64,   // no operands, 64 bit void operand
    ZODef,  // no operands, void operand with default size
    M,      // r/m value
    I,      // immediate
    I2,     // IGNORE           immediate
    II,     // immediate        immediate
    II16,   // immediate        immediate       void16
    O,      // opcode+reg.num
    O2,     // IGNORE           opcode+reg.num
    RM,     // ModRM:reg        ModRM:r/m
    MR,     // ModRM:r/m        ModRM:reg
    RMI,    // ModRM:reg        ModRM:r/m       immediate
    MRI,    // ModRM:r/m        ModRM:reg       immediate
    OI,     // opcode+reg.num   imm8/16/32/64
    MI,     // ModRM:r/m        imm8/16/32/64

    D,      // encode address or offset
    FD,     // AL/AX/EAX/RAX    Moffs   NA  NA
    TD,     // Moffs (w)        AL/AX/EAX/RAX   NA  NA

    // AvxOpcodes encodings
    RVM,   // ModRM:reg        (E)VEX:vvvv     ModRM:r/m
    MVR,   // ModRM:r/m        (E)VEX:vvvv     ModRM:reg
    RMV,   // ModRM:reg        ModRM:r/m       (E)VEX:vvvv
    RVMR,  // ModRM:reg        (E)VEX:vvvv     ModRM:r/m   imm8[7:4]:vvvv
    RVMI,  // ModRM:reg        (E)VEX:vvvv     ModRM:r/m   imm8
    VMI,   // (E)VEX:vvvv      ModRM:r/m       imm8
    VM,    // (E)VEX.vvvv      ModRM:r/m
    MV,    // ModRM:r/m        (E)VEX:vvvv
    vRMI,  // ModRM:reg        ModRM:r/m       imm8
    vMRI,  // ModRM:r/m        ModRM:reg       imm8
    vRM,   // ModRM:reg        ModRM:r/m
    vMR,   // ModRM:reg        ModRM:r/m
    vM,    // ModRm:r/m
    vZO,   //
};

pub const OpcodeAny = union {
    Op: Opcode,
    Avx: AvxOpcode,
};

pub const InstructionItem = struct {
    mnemonic: Mnemonic,
    signature: Signature,
    opcode: OpcodeAny,
    encoding: InstructionEncoding,
    default_size: DefaultSize,
    edge_case: OpcodeEdgeCase,
    mode_edge_case: OpcodeEdgeCase,

    fn create(
        mnem: Mnemonic,
        signature: Signature,
        opcode: var,
        en: InstructionEncoding,
        default_size: DefaultSize,
        version_and_features: var
    ) InstructionItem {
        _ = @setEvalBranchQuota(100000);
        // TODO: process version and features field
        // NOTE: If no version flags are given, can calculate version information
        // based of the signature/encoding/default_size properties as one of
        // _8086, _386, x64
        var edge_case = OpcodeEdgeCase.None;
        var mode_edge_case = OpcodeEdgeCase.None;


        if (@typeInfo(@TypeOf(version_and_features)) != .Struct) {
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(args)));
        }

        const opcode_any = switch (@TypeOf(opcode)) {
            Opcode => OpcodeAny { .Op = opcode },
            AvxOpcode => OpcodeAny { .Avx = opcode },
            else => @compileError("Expected Opcode or AvxOpcode, got: " ++ @TypeOf(opcode)),
        };

        inline for (version_and_features) |opt, i| {
            switch (@TypeOf(opt)) {
                CpuVersion => {
                    // TODO:
                },

                InstructionPrefix => {
                    // TODO:
                },

                OpcodeEdgeCase => {
                    switch (opt) {
                        .No32, .No64 => {
                            assert(mode_edge_case == .None);
                            mode_edge_case = opt;
                        },
                        .Undefined => {
                            // TODO:
                        },
                        else => {
                            assert(edge_case == .None);
                            edge_case = opt;
                        },
                    }
                },

                else => |bad_type| {
                    @compileError("Unsupported feature/version field type: " ++ @typeName(bad_type));
                },
            }
        }

        switch (default_size) {
            .RM32Strict => switch(signature.operands[0]) {
                .imm16 => {
                    assert(mode_edge_case == .None);
                    mode_edge_case = .No64;
                },
                else => {},
            },

            .RM64Strict => switch(signature.operands[0]) {
                .imm16,
                .imm32 => {
                    assert(mode_edge_case == .None);
                    mode_edge_case = .No64;
                },
                else => {},
            },

            else => {},
        }

        return InstructionItem {
            .mnemonic = mnem,
            .signature = signature,
            .opcode = opcode_any,
            .encoding = en,
            .default_size = default_size,
            .edge_case = edge_case,
            .mode_edge_case = mode_edge_case,
        };
    }

    pub inline fn hasEdgeCase(self: InstructionItem) bool {
        return self.edge_case != .None;
    }

    pub inline fn isMachineMatch(self: InstructionItem, machine: Machine) bool {
        switch (self.mode_edge_case) {
            .None => {},
            .No64 => if (machine.mode == .x64) return false,
            .No32 => if (machine.mode == .x86_32 or machine.mode == .x86_16) return false,
            else => unreachable,
        }
        return true;
    }

    pub fn matchesEdgeCase(
        self: InstructionItem,
        machine: Machine,
        op1: ?*const Operand,
        op2: ?*const Operand,
        op3: ?*const Operand,
        op4: ?*const Operand
    ) bool {
        return self.edge_case.isEdgeCase(self, machine.mode, op1, op2, op3, op4);
    }

    pub fn coerceImm(self: InstructionItem, op: ?*const Operand, pos: u8) Immediate {
        switch (self.signature.operands[pos]) {
            .imm8 => return op.?.*.Imm,
            .imm16 => return op.?.*.Imm.coerce(.Bit16),
            .imm32 => return op.?.*.Imm.coerce(.Bit32),
            .imm64 => return op.?.*.Imm.coerce(.Bit64),
            else => unreachable,
        }
    }

    pub fn encode(
        self: InstructionItem,
        machine: Machine,
        op1: ?*const Operand,
        op2: ?*const Operand,
        op3: ?*const Operand,
        op4: ?*const Operand
    ) AsmError!Instruction {
        return switch (self.encoding) {
            .ZO => machine.encodeOpcode(self.opcode.Op, op1, self.default_size),
            .ZO16 => machine.encodeOpcode(self.opcode.Op, &Operand.voidOperand(.WORD), self.default_size),
            .ZO32 => machine.encodeOpcode(self.opcode.Op, &Operand.voidOperand(.DWORD), self.default_size),
            .ZO64 => machine.encodeOpcode(self.opcode.Op, &Operand.voidOperand(.QWORD), self.default_size),
            .ZODef => machine.encodeOpcode(self.opcode.Op, &Operand.voidOperand(machine.dataSize()), self.default_size),
            .M => machine.encodeRm(self.opcode.Op, op1.?.*, self.default_size),
            .I => machine.encodeImmediate(self.opcode.Op, op2, self.coerceImm(op1, 0), self.default_size),
            .I2 => machine.encodeImmediate(self.opcode.Op, op1, self.coerceImm(op2, 1), self.default_size),
            .II => machine.encodeImmImm(self.opcode.Op, op3, self.coerceImm(op1, 0), self.coerceImm(op2, 1), self.default_size),
            .II16 => machine.encodeImmImm(self.opcode.Op, &Operand.voidOperand(.WORD), self.coerceImm(op1, 0), self.coerceImm(op2, 1), self.default_size),
            .O => machine.encodeOpcodeRegNum(self.opcode.Op, op1.?.*, self.default_size),
            .O2 => machine.encodeOpcodeRegNum(self.opcode.Op, op2.?.*, self.default_size),
            .D => machine.encodeAddress(self.opcode.Op, op1.?.*, self.default_size),
            .OI => machine.encodeOpcodeRegNumImmediate(self.opcode.Op, op1.?.*, self.coerceImm(op2, 1), self.default_size),
            .MI => machine.encodeRmImmediate(self.opcode.Op, op1.?.*, self.coerceImm(op2, 1), self.default_size),
            .RM => machine.encodeRegRm(self.opcode.Op, op1.?.*, op2.?.*, self.default_size),
            .RMI => machine.encodeRegRmImmediate(self.opcode.Op, op1.?.*, op2.?.*, self.coerceImm(op3, 2), self.default_size),
            .MRI => machine.encodeRegRmImmediate(self.opcode.Op, op2.?.*, op1.?.*, self.coerceImm(op3, 2), self.default_size),
            .MR => machine.encodeRegRm(self.opcode.Op, op2.?.*, op1.?.*, self.default_size),
            .FD => machine.encodeMOffset(self.opcode.Op, op1.?.*, op2.?.*, self.default_size),
            .TD => machine.encodeMOffset(self.opcode.Op, op2.?.*, op1.?.*, self.default_size),
            .RVM => machine.encodeAvx(self.opcode.Avx, op1, op2, op3, null, null, self.default_size),
            .MVR => machine.encodeAvx(self.opcode.Avx, op3, op2, op1, null, null, self.default_size),
            .RMV => machine.encodeAvx(self.opcode.Avx, op1, op3, op2, null, null, self.default_size),
            .VM => machine.encodeAvx(self.opcode.Avx, null, op1, op2, null, null, self.default_size),
            .MV => machine.encodeAvx(self.opcode.Avx, null, op2, op1, null, null, self.default_size),
            .RVMI => machine.encodeAvx(self.opcode.Avx, op1, op2, op3, null, op4, self.default_size),
            .VMI => machine.encodeAvx(self.opcode.Avx, null, op1, op2, null, op3, self.default_size),
            .RVMR => machine.encodeAvx(self.opcode.Avx, op1, op2, op3, op4, null, self.default_size),
            .vRMI => machine.encodeAvx(self.opcode.Avx, op1, null, op2, null, op3, self.default_size),
            .vMRI => machine.encodeAvx(self.opcode.Avx, op2, null, op1, null, op3, self.default_size),
            .vRM => machine.encodeAvx(self.opcode.Avx, op1, null, op2, null, null, self.default_size),
            .vMR => machine.encodeAvx(self.opcode.Avx, op2, null, op1, null, null, self.default_size),
            .vM => machine.encodeAvx(self.opcode.Avx, null, null, op1, null, null, self.default_size),
            .vZO => machine.encodeAvx(self.opcode.Avx, null, null, null, null, null, self.default_size),
        };
    }
};

/// Generate a map from Mnemonic -> index in the instruction database
fn genMnemonicLookupTable() [Mnemonic.count]u16 {
    comptime {
        var result: [Mnemonic.count]u16 = undefined;
        var current_mnem = Mnemonic._mnemonic_final;

        _ = @setEvalBranchQuota(50000);

        for (result) |*val| {
            val.* = 0xffff;
        }

        for (instruction_database) |item, i| {
            if (item.mnemonic != current_mnem) {
                current_mnem = item.mnemonic;

                if (current_mnem == ._mnemonic_final) {
                    break;
                }
                if (result[@enumToInt(current_mnem)] != 0xffff) {
                    @compileError("Mnemonic mislocated in lookup table. " ++ @tagName(current_mnem));
                }
                result[@enumToInt(current_mnem)] = @intCast(u16, i);
            }
        }

        if (false) {
            // Count the number of unimplemented mnemonics
            var count: u16 = 0;
            for (result) |val, mnem_index| {
                if (val == 0xffff) {
                    @compileLog(@intToEnum(Mnemonic, mnem_index));
                    count += 1;
                }
            }
            @compileLog("Unreferenced mnemonics: ", count);
        }

        return result;
    }
}

pub fn lookupMnemonic(mnem: Mnemonic) usize {
    const result = lookup_table[@enumToInt(mnem)];
    if (result == 0xffff) {
        std.debug.panic("Instruction {} not implemented yet", .{mnem});
    }
    return result;
}

pub fn getDatabaseItem(index: usize) *const InstructionItem {
    return &instruction_database[index];
}

pub const lookup_table: [Mnemonic.count]u16 = genMnemonicLookupTable();

const Op1 = x86.Opcode.op1;
const Op2 = x86.Opcode.op2;
const Op3 = x86.Opcode.op3;

const Op1r = x86.Opcode.op1r;
const Op2r = x86.Opcode.op2r;
const Op3r = x86.Opcode.op3r;

// Opcodes with compulsory prefix that needs to precede other prefixes
const preOp1 = x86.Opcode.preOp1;
const preOp2 = x86.Opcode.preOp2;
const preOp1r = x86.Opcode.preOp1r;
const preOp2r = x86.Opcode.preOp2r;
const preOp3 = x86.Opcode.preOp3;
const preOp3r = x86.Opcode.preOp3r;

// Opcodes that are actually composed of multiple instructions
// eg: FSTENV needs prefix 0x9B before other prefixes, because 0x9B is
// actually the opcode FWAIT/WAIT
const compOp2 = x86.Opcode.compOp2;
const compOp1r = x86.Opcode.compOp1r;

const ops0 = Signature.ops0;
const ops1 = Signature.ops1;
const ops2 = Signature.ops2;
const ops3 = Signature.ops3;
const ops4 = Signature.ops4;

const vex = x86.avx.AvxOpcode.vex;
const vexr = x86.avx.AvxOpcode.vexr;
const evex = x86.avx.AvxOpcode.evex;
const evexr = x86.avx.AvxOpcode.evexr;
const xop = x86.avx.AvxOpcode.xop;
const xopr = x86.avx.AvxOpcode.xopr;

const instr = InstructionItem.create;

const cpu = CpuVersion;
const edge = OpcodeEdgeCase;
const pre = InstructionPrefix;

const No64 = OpcodeEdgeCase.No64;
const No32 = OpcodeEdgeCase.No32;
const Sign = OpcodeEdgeCase.Sign;
const NoSign = OpcodeEdgeCase.NoSign;

const _186 = cpu._186;
const _286 = cpu._286;
const _386 = cpu._386;
const _486 = cpu._486;
const Pent = cpu.Pent;
const x86_64 = cpu.x64;
const _087 = cpu._087;
const _187 = cpu._187;
const _287 = cpu._287;
const _387 = cpu._387;
const VT_x = cpu.VT_x;
const ABM = cpu.ABM;
const BMI1 = cpu.BMI1;
const BMI2 = cpu.BMI2;
const TBM = cpu.TBM;
const MMX = cpu.AVX;
const SSE = cpu.SSE;
const SSE2 = cpu.SSE2;
const SSE3 = cpu.SSE3;
const SSSE3 = cpu.SSSE3;
const SSE4_a = cpu.SSE4_a;
const SSE4_1 = cpu.SSE4_1;
const SSE4_2 = cpu.SSE4_2;
const AVX = cpu.AVX;
const AVX2 = cpu.AVX2;
const AVX512F = cpu.AVX512F;
const AVX512CD = cpu.AVX512CD;
const AVX512ER = cpu.AVX512ER;
const AVX512PF = cpu.AVX512PF;
const AVX512VL = cpu.AVX512VL;
const AVX512BW = cpu.AVX512BW;
const AVX512DQ = cpu.AVX512DQ;

const ADX = cpu.ADX;
const AES = cpu.AES;
const CLDEMOTE = cpu.CLDEMOTE;
const CLFLUSHOPT = cpu.CLFLUSHOPT;
const CET_IBT = cpu.CET_IBT;
const CET_SS = cpu.CET_SS;
const CLWB = cpu.CLWB;
const FMA = cpu.FMA;
const FSGSBASE = cpu.FSGSBASE;
const FXSR = cpu.FXSR;
const F16C = cpu.F16C;
const SGX = cpu.SGX;
const SMX = cpu.SMX;
const GFNI = cpu.GFNI;
const HLE = cpu.HLE;
const INVPCID = cpu.INVPCID;
const MOVBE = cpu.MOVBE;
const MOVDIRI = cpu.MOVDIRI;
const MOVDIR64B = cpu.MOVDIR64B;
const MPX = cpu.MPX;
const OSPKE = cpu.OSPKE;
const PKRU = cpu.PKRU;
const PCLMULQDQ = cpu.PCLMULQDQ;
const PREFETCHW = cpu.PREFETCHW;
const PTWRITE = cpu.PTWRITE;
const RDPID = cpu.RDPID;
const RDRAND = cpu.RDRAND;
const RDSEED = cpu.RDSEED;
const RTM = cpu.RTM;
const SHA = cpu.SHA;
const SMAP = cpu.SMAP;
const TDX = cpu.TDX;
const WAITPKG = cpu.WAITPKG;
const VAES = cpu.VAES;
const VPCLMULQDQ = cpu.VPCLMULQDQ;
const XSAVE = cpu.XSAVE;
const XSAVEC = cpu.XSAVEC;
const XSAVEOPT = cpu.XSAVEOPT;
const XSS = cpu.XSS;

// NOTE: Entries into this table should be from most specific to most general.
// For example, if a instruction takes both a reg64 and rm64 value, an operand
// of Operand.register(.RAX) can match both, while a Operand.registerRm(.RAX)
// can only match the rm64 value.
//
// Putting the most specific opcodes first enables us to reach every possible
// encoding for an instruction.
//
// User supplied immediates without an explicit size are allowed to match
// against larger immediate sizes:
//      * imm8  <-> imm8,  imm16, imm32, imm64
//      * imm16 <-> imm16, imm32, imm64
//      * imm32 <-> imm32, imm64
// So if there are multiple operand signatures that only differ by there
// immediate size, we must place the version with the smaller immediate size
// first. This insures that the shortest encoding is chosen when the operand
// is an Immediate without a fixed size.
//
// TODO: string functions should support memory operand(s) to select 66 and/or 67
// prefixes. eg:
//      66 67 a7 -> cmps   WORD ds:[esi],WORD es:[edi]
//      67 a7 -> cmps   DWORD ds:[esi],DWORD es:[edi]
//      a7 -> cmps   DWORD ds:[rsi],DWORD es:[rdi]
// OUTS / OUTSB / OUTSW / OUTSD
// MOVS / MOVSB / MOVSW / MOVSD / MOVSQ
// LODS / LODSB / LODSW / LODSD / LODSQ
// CMPS / CMPSB / CMPSW / CMPSD / CMPSQ
// STOS / STOSB / STOSW / STOSD / STOSQ
// SCAS / SCASB / SCASW / SCASD / SCASQ
//
// TODO: AVX512 needs to handle `disp*8` feature
pub const instruction_database = [_]InstructionItem {
//
// 8086 / 80186
//

// AAA
    instr(.AAA,     ops0(),                     Op1(0x37),              .ZO, .ZO32Only,   .{No64} ),
// AAD
    instr(.AAD,     ops0(),                     Op2(0xD5, 0x0A),        .ZO, .ZO32Only,   .{No64} ),
    instr(.AAD,     ops1(.imm8),                Op1(0xD5),              .I,  .ZO32Only,   .{No64} ),
// AAM
    instr(.AAM,     ops0(),                     Op2(0xD4, 0x0A),        .ZO, .ZO32Only,   .{No64} ),
    instr(.AAM,     ops1(.imm8),                Op1(0xD4),              .I,  .ZO32Only,   .{No64} ),
// AAS
    instr(.AAS,     ops0(),                     Op1(0x3F),              .ZO, .ZO32Only,   .{No64} ),
// ADD
    instr(.ADD,     ops2(.reg_al, .imm8),       Op1(0x04),              .I2, .RM8,        .{} ),
    instr(.ADD,     ops2(.rm8, .imm8),          Op1r(0x80, 0),          .MI, .RM8,        .{} ),
    instr(.ADD,     ops2(.rm16, .imm8),         Op1r(0x83, 0),          .MI, .RM32_I8,    .{Sign} ),
    instr(.ADD,     ops2(.rm32, .imm8),         Op1r(0x83, 0),          .MI, .RM32_I8,    .{Sign} ),
    instr(.ADD,     ops2(.rm64, .imm8),         Op1r(0x83, 0),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.ADD,     ops2(.reg_ax, .imm16),      Op1(0x05),              .I2, .RM32,       .{} ),
    instr(.ADD,     ops2(.reg_eax, .imm32),     Op1(0x05),              .I2, .RM32,       .{} ),
    instr(.ADD,     ops2(.reg_rax, .imm32),     Op1(0x05),              .I2, .RM32,       .{Sign} ),
    //
    instr(.ADD,     ops2(.rm16, .imm16),        Op1r(0x81, 0),          .MI, .RM32,       .{} ),
    instr(.ADD,     ops2(.rm32, .imm32),        Op1r(0x81, 0),          .MI, .RM32,       .{} ),
    instr(.ADD,     ops2(.rm64, .imm32),        Op1r(0x81, 0),          .MI, .RM32,       .{Sign} ),
    //
    instr(.ADD,     ops2(.rm8, .reg8),          Op1(0x00),              .MR, .RM8,        .{} ),
    instr(.ADD,     ops2(.rm16, .reg16),        Op1(0x01),              .MR, .RM32,       .{} ),
    instr(.ADD,     ops2(.rm32, .reg32),        Op1(0x01),              .MR, .RM32,       .{} ),
    instr(.ADD,     ops2(.rm64, .reg64),        Op1(0x01),              .MR, .RM32,       .{} ),
    //
    instr(.ADD,     ops2(.reg8, .rm8),          Op1(0x02),              .RM, .RM8,        .{} ),
    instr(.ADD,     ops2(.reg16, .rm16),        Op1(0x03),              .RM, .RM32,       .{} ),
    instr(.ADD,     ops2(.reg32, .rm32),        Op1(0x03),              .RM, .RM32,       .{} ),
    instr(.ADD,     ops2(.reg64, .rm64),        Op1(0x03),              .RM, .RM32,       .{} ),
// ADC
    instr(.ADC,     ops2(.reg_al, .imm8),       Op1(0x14),              .I2, .RM8,        .{} ),
    instr(.ADC,     ops2(.rm8, .imm8),          Op1r(0x80, 2),          .MI, .RM8,        .{} ),
    instr(.ADC,     ops2(.rm16, .imm8),         Op1r(0x83, 2),          .MI, .RM32_I8,    .{Sign} ),
    instr(.ADC,     ops2(.rm32, .imm8),         Op1r(0x83, 2),          .MI, .RM32_I8,    .{Sign} ),
    instr(.ADC,     ops2(.rm64, .imm8),         Op1r(0x83, 2),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.ADC,     ops2(.reg_ax, .imm16),      Op1(0x15),              .I2, .RM32,       .{} ),
    instr(.ADC,     ops2(.reg_eax, .imm32),     Op1(0x15),              .I2, .RM32,       .{} ),
    instr(.ADC,     ops2(.reg_rax, .imm32),     Op1(0x15),              .I2, .RM32,       .{Sign} ),
    //
    instr(.ADC,     ops2(.rm16, .imm16),        Op1r(0x81, 2),          .MI, .RM32,       .{} ),
    instr(.ADC,     ops2(.rm32, .imm32),        Op1r(0x81, 2),          .MI, .RM32,       .{} ),
    instr(.ADC,     ops2(.rm64, .imm32),        Op1r(0x81, 2),          .MI, .RM32,       .{Sign} ),
    //
    instr(.ADC,     ops2(.rm8, .reg8),          Op1(0x10),              .MR, .RM8,        .{} ),
    instr(.ADC,     ops2(.rm16, .reg16),        Op1(0x11),              .MR, .RM32,       .{} ),
    instr(.ADC,     ops2(.rm32, .reg32),        Op1(0x11),              .MR, .RM32,       .{} ),
    instr(.ADC,     ops2(.rm64, .reg64),        Op1(0x11),              .MR, .RM32,       .{} ),
    //
    instr(.ADC,     ops2(.reg8, .rm8),          Op1(0x12),              .RM, .RM8,        .{} ),
    instr(.ADC,     ops2(.reg16, .rm16),        Op1(0x13),              .RM, .RM32,       .{} ),
    instr(.ADC,     ops2(.reg32, .rm32),        Op1(0x13),              .RM, .RM32,       .{} ),
    instr(.ADC,     ops2(.reg64, .rm64),        Op1(0x13),              .RM, .RM32,       .{} ),
// AND
    instr(.AND,     ops2(.reg_al, .imm8),       Op1(0x24),              .I2, .RM8,        .{} ),
    instr(.AND,     ops2(.rm8, .imm8),          Op1r(0x80, 4),          .MI, .RM8,        .{} ),
    instr(.AND,     ops2(.rm16, .imm8),         Op1r(0x83, 4),          .MI, .RM32_I8,    .{Sign} ),
    instr(.AND,     ops2(.rm32, .imm8),         Op1r(0x83, 4),          .MI, .RM32_I8,    .{Sign} ),
    instr(.AND,     ops2(.rm64, .imm8),         Op1r(0x83, 4),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.AND,     ops2(.reg_ax, .imm16),      Op1(0x25),              .I2, .RM32,       .{} ),
    instr(.AND,     ops2(.reg_eax, .imm32),     Op1(0x25),              .I2, .RM32,       .{} ),
    instr(.AND,     ops2(.reg_rax, .imm32),     Op1(0x25),              .I2, .RM32,       .{Sign} ),
    //
    instr(.AND,     ops2(.rm16, .imm16),        Op1r(0x81, 4),          .MI, .RM32,       .{} ),
    instr(.AND,     ops2(.rm32, .imm32),        Op1r(0x81, 4),          .MI, .RM32,       .{} ),
    instr(.AND,     ops2(.rm64, .imm32),        Op1r(0x81, 4),          .MI, .RM32,       .{Sign} ),
    //
    instr(.AND,     ops2(.rm8, .reg8),          Op1(0x20),              .MR, .RM8,        .{} ),
    instr(.AND,     ops2(.rm16, .reg16),        Op1(0x21),              .MR, .RM32,       .{} ),
    instr(.AND,     ops2(.rm32, .reg32),        Op1(0x21),              .MR, .RM32,       .{} ),
    instr(.AND,     ops2(.rm64, .reg64),        Op1(0x21),              .MR, .RM32,       .{} ),
    //
    instr(.AND,     ops2(.reg8, .rm8),          Op1(0x22),              .RM, .RM8,        .{} ),
    instr(.AND,     ops2(.reg16, .rm16),        Op1(0x23),              .RM, .RM32,       .{} ),
    instr(.AND,     ops2(.reg32, .rm32),        Op1(0x23),              .RM, .RM32,       .{} ),
    instr(.AND,     ops2(.reg64, .rm64),        Op1(0x23),              .RM, .RM32,       .{} ),
// BOUND
    instr(.BOUND,   ops2(.reg16, .rm16),        Op1(0x62),              .RM, .RM32,       .{No64, _186} ),
    instr(.BOUND,   ops2(.reg32, .rm32),        Op1(0x62),              .RM, .RM32,       .{No64, _186} ),
// CALL
    instr(.CALL,    ops1(.imm16),               Op1(0xE8),              .I,  .RM32Strict, .{} ),
    instr(.CALL,    ops1(.imm32),               Op1(0xE8),              .I,  .RM32Strict, .{} ),
    //
    instr(.CALL,    ops1(.rm16),                Op1r(0xFF, 2),          .M,  .RM64Strict, .{} ),
    instr(.CALL,    ops1(.rm32),                Op1r(0xFF, 2),          .M,  .RM64Strict, .{} ),
    instr(.CALL,    ops1(.rm64),                Op1r(0xFF, 2),          .M,  .RM64Strict, .{} ),
    //
    instr(.CALL,    ops1(.ptr16_16),            Op1r(0x9A, 4),          .D,  .RM32Only,   .{} ),
    instr(.CALL,    ops1(.ptr16_32),            Op1r(0x9A, 4),          .D,  .RM32Only,   .{} ),
    //
    instr(.CALL,    ops1(.m16_16),              Op1r(0xFF, 3),          .M,  .RM32,       .{} ),
    instr(.CALL,    ops1(.m16_32),              Op1r(0xFF, 3),          .M,  .RM32,       .{} ),
    instr(.CALL,    ops1(.m16_64),              Op1r(0xFF, 3),          .M,  .RM32,       .{} ),
// CBW
    instr(.CBW,     ops0(),                     Op1(0x98),              .ZO16, .RM32,     .{} ),
    instr(.CWDE,    ops0(),                     Op1(0x98),              .ZO32, .RM32,     .{_386} ),
    instr(.CDQE,    ops0(),                     Op1(0x98),              .ZO64, .RM32,     .{x86_64} ),
    //
    instr(.CWD,     ops0(),                     Op1(0x99),              .ZO16, .RM32,     .{} ),
    instr(.CDQ,     ops0(),                     Op1(0x99),              .ZO32, .RM32,     .{_386} ),
    instr(.CQO,     ops0(),                     Op1(0x99),              .ZO64, .RM32,     .{x86_64} ),
// CLC
    instr(.CLC,     ops0(),                     Op1(0xF8),              .ZO, .ZO,         .{} ),
// CLD
    instr(.CLD,     ops0(),                     Op1(0xFC),              .ZO, .ZO,         .{} ),
// CLI
    instr(.CLI,     ops0(),                     Op1(0xFA),              .ZO, .ZO,         .{} ),
// CMC
    instr(.CMC,     ops0(),                     Op1(0xF5),              .ZO, .ZO,         .{} ),
// CMP
    instr(.CMP,     ops2(.reg_al, .imm8),       Op1(0x3C),              .I2, .RM8,        .{} ),
    instr(.CMP,     ops2(.rm8, .imm8),          Op1r(0x80, 7),          .MI, .RM8,        .{} ),
    instr(.CMP,     ops2(.rm16, .imm8),         Op1r(0x83, 7),          .MI, .RM32_I8,    .{Sign} ),
    instr(.CMP,     ops2(.rm32, .imm8),         Op1r(0x83, 7),          .MI, .RM32_I8,    .{Sign} ),
    instr(.CMP,     ops2(.rm64, .imm8),         Op1r(0x83, 7),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.CMP,     ops2(.reg_ax, .imm16),      Op1(0x3D),              .I2, .RM32,       .{} ),
    instr(.CMP,     ops2(.reg_eax, .imm32),     Op1(0x3D),              .I2, .RM32,       .{} ),
    instr(.CMP,     ops2(.reg_rax, .imm32),     Op1(0x3D),              .I2, .RM32,       .{Sign} ),
    //
    instr(.CMP,     ops2(.rm16, .imm16),        Op1r(0x81, 7),          .MI, .RM32,       .{} ),
    instr(.CMP,     ops2(.rm32, .imm32),        Op1r(0x81, 7),          .MI, .RM32,       .{} ),
    instr(.CMP,     ops2(.rm64, .imm32),        Op1r(0x81, 7),          .MI, .RM32,       .{Sign} ),
    //
    instr(.CMP,     ops2(.rm8, .reg8),          Op1(0x38),              .MR, .RM8,        .{} ),
    instr(.CMP,     ops2(.rm16, .reg16),        Op1(0x39),              .MR, .RM32,       .{} ),
    instr(.CMP,     ops2(.rm32, .reg32),        Op1(0x39),              .MR, .RM32,       .{} ),
    instr(.CMP,     ops2(.rm64, .reg64),        Op1(0x39),              .MR, .RM32,       .{} ),
    //
    instr(.CMP,     ops2(.reg8, .rm8),          Op1(0x3A),              .RM, .RM8,        .{} ),
    instr(.CMP,     ops2(.reg16, .rm16),        Op1(0x3B),              .RM, .RM32,       .{} ),
    instr(.CMP,     ops2(.reg32, .rm32),        Op1(0x3B),              .RM, .RM32,       .{} ),
    instr(.CMP,     ops2(.reg64, .rm64),        Op1(0x3B),              .RM, .RM32,       .{} ),
// CMPS / CMPSB / CMPSW / CMPSD / CMPSQ
    instr(.CMPS,    ops1(._void8),              Op1(0xA6),              .ZO, .RM8,        .{} ),
    instr(.CMPS,    ops1(._void),               Op1(0xA7),              .ZO, .RM32,       .{} ),
    //
    instr(.CMPSB,   ops0(),                     Op1(0xA6),              .ZO,   .RM8,      .{} ),
    instr(.CMPSW,   ops0(),                     Op1(0xA7),              .ZO16, .RM32,     .{} ),
    // HACK: CMPSD is overloaded mnemonic (compare string) vs (compare scalar double precision)
    // instr(.CMPSD,   ops0(),                     Op1(0xA7),              .ZO32, .RM32,     .{_386} ),
    instr(.CMPSQ,   ops0(),                     Op1(0xA7),              .ZO64, .RM32,     .{x86_64} ),
// DAA
    instr(.DAA,     ops0(),                     Op1(0x27),              .ZO, .ZO32Only,   .{} ),
// DAS
    instr(.DAS,     ops0(),                     Op1(0x2F),              .ZO, .ZO32Only,   .{} ),
// DEC
    instr(.DEC,     ops1(.reg16),               Op1(0x48),              .O,  .RM32,       .{No64} ),
    instr(.DEC,     ops1(.reg32),               Op1(0x48),              .O,  .RM32,       .{No64} ),
    instr(.DEC,     ops1(.rm8),                 Op1r(0xFE, 1),          .M,  .RM8,        .{} ),
    instr(.DEC,     ops1(.rm16),                Op1r(0xFF, 1),          .M,  .RM32,       .{} ),
    instr(.DEC,     ops1(.rm32),                Op1r(0xFF, 1),          .M,  .RM32,       .{} ),
    instr(.DEC,     ops1(.rm64),                Op1r(0xFF, 1),          .M,  .RM32,       .{} ),
// DIV
    instr(.DIV,     ops1(.rm8),                 Op1r(0xF6, 6),          .M,  .RM8,        .{} ),
    instr(.DIV,     ops1(.rm16),                Op1r(0xF7, 6),          .M,  .RM32,       .{} ),
    instr(.DIV,     ops1(.rm32),                Op1r(0xF7, 6),          .M,  .RM32,       .{} ),
    instr(.DIV,     ops1(.rm64),                Op1r(0xF7, 6),          .M,  .RM32,       .{} ),
// ENTER
    instr(.ENTER,   ops2(.imm16, .imm8),        Op1(0xC8),              .II, .RM64_16,    .{_186} ),
    instr(.ENTERW,  ops2(.imm16, .imm8),        Op1(0xC8),              .II16, .RM64_16,  .{_186} ),
// HLT
    instr(.HLT,     ops0(),                     Op1(0xF4),              .ZO, .ZO,         .{} ),
// IDIV
    instr(.IDIV,    ops1(.rm8),                 Op1r(0xF6, 7),          .M,  .RM8,        .{} ),
    instr(.IDIV,    ops1(.rm16),                Op1r(0xF7, 7),          .M,  .RM32,       .{} ),
    instr(.IDIV,    ops1(.rm32),                Op1r(0xF7, 7),          .M,  .RM32,       .{} ),
    instr(.IDIV,    ops1(.rm64),                Op1r(0xF7, 7),          .M,  .RM32,       .{} ),
// IMUL
    instr(.IMUL,    ops1(.rm8),                 Op1r(0xF6, 5),          .M,  .RM8,        .{} ),
    instr(.IMUL,    ops1(.rm16),                Op1r(0xF7, 5),          .M,  .RM32,       .{} ),
    instr(.IMUL,    ops1(.rm32),                Op1r(0xF7, 5),          .M,  .RM32,       .{} ),
    instr(.IMUL,    ops1(.rm64),                Op1r(0xF7, 5),          .M,  .RM32,       .{} ),
    //
    instr(.IMUL,    ops2(.reg16, .rm16),        Op2(0x0F, 0xAF),        .RM, .RM32,       .{} ),
    instr(.IMUL,    ops2(.reg32, .rm32),        Op2(0x0F, 0xAF),        .RM, .RM32,       .{} ),
    instr(.IMUL,    ops2(.reg64, .rm64),        Op2(0x0F, 0xAF),        .RM, .RM32,       .{} ),
    //
    instr(.IMUL,    ops3(.reg16, .rm16, .imm8), Op1(0x6B),              .RMI, .RM32_I8,   .{Sign, _186} ),
    instr(.IMUL,    ops3(.reg32, .rm32, .imm8), Op1(0x6B),              .RMI, .RM32_I8,   .{Sign, _386} ),
    instr(.IMUL,    ops3(.reg64, .rm64, .imm8), Op1(0x6B),              .RMI, .RM32_I8,   .{Sign, x86_64} ),
    //
    instr(.IMUL,    ops3(.reg16, .rm16, .imm16),Op1(0x69),              .RMI, .RM32,      .{_186} ),
    instr(.IMUL,    ops3(.reg32, .rm32, .imm32),Op1(0x69),              .RMI, .RM32,      .{_386} ),
    instr(.IMUL,    ops3(.reg64, .rm64, .imm32),Op1(0x69),              .RMI, .RM32,      .{Sign, x86_64} ),
// IN
    instr(.IN,      ops2(.reg_al, .imm8),       Op1(0xE4),              .I2, .RM8,        .{} ),
    instr(.IN,      ops2(.reg_ax, .imm8),       Op1(0xE5),              .I2, .RM32,       .{} ),
    instr(.IN,      ops2(.reg_eax, .imm8),      Op1(0xE5),              .I2, .RM32,       .{} ),
    instr(.IN,      ops2(.reg_al, .reg_dx),     Op1(0xEC),              .ZO, .RM8,        .{} ),
    instr(.IN,      ops2(.reg_ax, .reg_dx),     Op1(0xED),              .ZO16, .RM32,     .{} ),
    instr(.IN,      ops2(.reg_eax, .reg_dx),    Op1(0xED),              .ZO32, .RM32,     .{} ),
// INC
    instr(.INC,     ops1(.reg16),               Op1(0x40),              .O,  .RM32,       .{No64} ),
    instr(.INC,     ops1(.reg32),               Op1(0x40),              .O,  .RM32,       .{No64} ),
    instr(.INC,     ops1(.rm8),                 Op1r(0xFE, 0),          .M,  .RM8,        .{} ),
    instr(.INC,     ops1(.rm16),                Op1r(0xFF, 0),          .M,  .RM32,       .{} ),
    instr(.INC,     ops1(.rm32),                Op1r(0xFF, 0),          .M,  .RM32,       .{} ),
    instr(.INC,     ops1(.rm64),                Op1r(0xFF, 0),          .M,  .RM32,       .{} ),
// INS / INSB / INSW / INSD
    instr(.INS,     ops1(._void8),              Op1(0x6C),              .ZO, .RM8,        .{_186} ),
    instr(.INS,     ops1(._void),               Op1(0x6D),              .ZO, .RM32,       .{_186} ),
    //
    instr(.INSB,    ops0(),                     Op1(0x6C),              .ZO,   .RM8,      .{_186} ),
    instr(.INSW,    ops0(),                     Op1(0x6D),              .ZO16, .RM32,     .{_186} ),
    instr(.INSD,    ops0(),                     Op1(0x6D),              .ZO32, .RM32,     .{_386} ),
// INT
    instr(.INT3,    ops0(),                     Op1(0xCC),              .ZO, .ZO,         .{} ),
    instr(.INT,     ops1(.imm8),                Op1(0xCD),              .I,  .RM8,        .{} ),
    instr(.INTO,    ops0(),                     Op1(0xCE),              .ZO, .ZO32Only,   .{} ),
    instr(.INT1,    ops0(),                     Op1(0xF1),              .ZO, .ZO,         .{} ),
// IRET
    instr(.IRET,    ops1(._void),               Op1(0xCF),              .ZO,   .RM32,     .{} ),
    instr(.IRET,    ops0(),                     Op1(0xCF),              .ZO16, .RM32,     .{} ),
    instr(.IRETD,   ops0(),                     Op1(0xCF),              .ZO32, .RM32,     .{_386} ),
    instr(.IRETQ,   ops0(),                     Op1(0xCF),              .ZO64, .RM32,     .{x86_64} ),
// Jcc
    instr(.JCXZ,    ops1(.imm8),                Op1(0xE3),              .I, .R_Over16,    .{Sign, No64} ),
    instr(.JECXZ,   ops1(.imm8),                Op1(0xE3),              .I, .R_Over32,    .{Sign, _386} ),
    instr(.JRCXZ,   ops1(.imm8),                Op1(0xE3),              .I, .RM8,         .{Sign, No32, x86_64} ),
    //
    instr(.JA,      ops1(.imm8),                Op1(0x77),              .I, .RM8,         .{Sign} ),
    instr(.JA,      ops1(.imm16),               Op2(0x0F, 0x87),        .I, .RM32Strict,  .{Sign} ),
    instr(.JA,      ops1(.imm32),               Op2(0x0F, 0x87),        .I, .RM32Strict,  .{Sign} ),
    instr(.JAE,     ops1(.imm8),                Op1(0x73),              .I, .RM8,         .{Sign} ),
    instr(.JAE,     ops1(.imm16),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JAE,     ops1(.imm32),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JB,      ops1(.imm8),                Op1(0x72),              .I, .RM8,         .{Sign} ),
    instr(.JB,      ops1(.imm16),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JB,      ops1(.imm32),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JBE,     ops1(.imm8),                Op1(0x76),              .I, .RM8,         .{Sign} ),
    instr(.JBE,     ops1(.imm16),               Op2(0x0F, 0x86),        .I, .RM32Strict,  .{Sign} ),
    instr(.JBE,     ops1(.imm32),               Op2(0x0F, 0x86),        .I, .RM32Strict,  .{Sign} ),
    instr(.JC,      ops1(.imm8),                Op1(0x72),              .I, .RM8,         .{Sign} ),
    instr(.JC,      ops1(.imm16),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JC,      ops1(.imm32),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JE,      ops1(.imm8),                Op1(0x74),              .I, .RM8,         .{Sign} ),
    instr(.JE,      ops1(.imm16),               Op2(0x0F, 0x84),        .I, .RM32Strict,  .{Sign} ),
    instr(.JE,      ops1(.imm32),               Op2(0x0F, 0x84),        .I, .RM32Strict,  .{Sign} ),
    instr(.JG,      ops1(.imm8),                Op1(0x7F),              .I, .RM8,         .{Sign} ),
    instr(.JG,      ops1(.imm16),               Op2(0x0F, 0x8F),        .I, .RM32Strict,  .{Sign} ),
    instr(.JG,      ops1(.imm32),               Op2(0x0F, 0x8F),        .I, .RM32Strict,  .{Sign} ),
    instr(.JGE,     ops1(.imm8),                Op1(0x7D),              .I, .RM8,         .{Sign} ),
    instr(.JGE,     ops1(.imm16),               Op2(0x0F, 0x8D),        .I, .RM32Strict,  .{Sign} ),
    instr(.JGE,     ops1(.imm32),               Op2(0x0F, 0x8D),        .I, .RM32Strict,  .{Sign} ),
    instr(.JL,      ops1(.imm8),                Op1(0x7C),              .I, .RM8,         .{Sign} ),
    instr(.JL,      ops1(.imm16),               Op2(0x0F, 0x8C),        .I, .RM32Strict,  .{Sign} ),
    instr(.JL,      ops1(.imm32),               Op2(0x0F, 0x8C),        .I, .RM32Strict,  .{Sign} ),
    instr(.JLE,     ops1(.imm8),                Op1(0x7E),              .I, .RM8,         .{Sign} ),
    instr(.JLE,     ops1(.imm16),               Op2(0x0F, 0x8E),        .I, .RM32Strict,  .{Sign} ),
    instr(.JLE,     ops1(.imm32),               Op2(0x0F, 0x8E),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNA,     ops1(.imm8),                Op1(0x76),              .I, .RM8,         .{Sign} ),
    instr(.JNA,     ops1(.imm16),               Op2(0x0F, 0x86),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNA,     ops1(.imm32),               Op2(0x0F, 0x86),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNAE,    ops1(.imm8),                Op1(0x72),              .I, .RM8,         .{Sign} ),
    instr(.JNAE,    ops1(.imm16),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNAE,    ops1(.imm32),               Op2(0x0F, 0x82),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNB,     ops1(.imm8),                Op1(0x73),              .I, .RM8,         .{Sign} ),
    instr(.JNB,     ops1(.imm16),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNB,     ops1(.imm32),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNBE,    ops1(.imm8),                Op1(0x77),              .I, .RM8,         .{Sign} ),
    instr(.JNBE,    ops1(.imm16),               Op2(0x0F, 0x87),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNBE,    ops1(.imm32),               Op2(0x0F, 0x87),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNC,     ops1(.imm8),                Op1(0x73),              .I, .RM8,         .{Sign} ),
    instr(.JNC,     ops1(.imm16),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNC,     ops1(.imm32),               Op2(0x0F, 0x83),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNE,     ops1(.imm8),                Op1(0x75),              .I, .RM8,         .{Sign} ),
    instr(.JNE,     ops1(.imm16),               Op2(0x0F, 0x85),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNE,     ops1(.imm32),               Op2(0x0F, 0x85),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNG,     ops1(.imm8),                Op1(0x7E),              .I, .RM8,         .{Sign} ),
    instr(.JNG,     ops1(.imm16),               Op2(0x0F, 0x8E),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNG,     ops1(.imm32),               Op2(0x0F, 0x8E),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNGE,    ops1(.imm8),                Op1(0x7C),              .I, .RM8,         .{Sign} ),
    instr(.JNGE,    ops1(.imm16),               Op2(0x0F, 0x8C),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNGE,    ops1(.imm32),               Op2(0x0F, 0x8C),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNL,     ops1(.imm8),                Op1(0x7D),              .I, .RM8,         .{Sign} ),
    instr(.JNL,     ops1(.imm16),               Op2(0x0F, 0x8D),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNL,     ops1(.imm32),               Op2(0x0F, 0x8D),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNLE,    ops1(.imm8),                Op1(0x7F),              .I, .RM8,         .{Sign} ),
    instr(.JNLE,    ops1(.imm16),               Op2(0x0F, 0x8F),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNLE,    ops1(.imm32),               Op2(0x0F, 0x8F),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNO,     ops1(.imm8),                Op1(0x71),              .I, .RM8,         .{Sign} ),
    instr(.JNO,     ops1(.imm16),               Op2(0x0F, 0x81),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNO,     ops1(.imm32),               Op2(0x0F, 0x81),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNP,     ops1(.imm8),                Op1(0x7B),              .I, .RM8,         .{Sign} ),
    instr(.JNP,     ops1(.imm16),               Op2(0x0F, 0x8B),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNP,     ops1(.imm32),               Op2(0x0F, 0x8B),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNS,     ops1(.imm8),                Op1(0x79),              .I, .RM8,         .{Sign} ),
    instr(.JNS,     ops1(.imm16),               Op2(0x0F, 0x89),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNS,     ops1(.imm32),               Op2(0x0F, 0x89),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNZ,     ops1(.imm8),                Op1(0x75),              .I, .RM8,         .{Sign} ),
    instr(.JNZ,     ops1(.imm16),               Op2(0x0F, 0x85),        .I, .RM32Strict,  .{Sign} ),
    instr(.JNZ,     ops1(.imm32),               Op2(0x0F, 0x85),        .I, .RM32Strict,  .{Sign} ),
    instr(.JO,      ops1(.imm8),                Op1(0x70),              .I, .RM8,         .{Sign} ),
    instr(.JO,      ops1(.imm16),               Op2(0x0F, 0x80),        .I, .RM32Strict,  .{Sign} ),
    instr(.JO,      ops1(.imm32),               Op2(0x0F, 0x80),        .I, .RM32Strict,  .{Sign} ),
    instr(.JP,      ops1(.imm8),                Op1(0x7A),              .I, .RM8,         .{Sign} ),
    instr(.JP,      ops1(.imm16),               Op2(0x0F, 0x8A),        .I, .RM32Strict,  .{Sign} ),
    instr(.JP,      ops1(.imm32),               Op2(0x0F, 0x8A),        .I, .RM32Strict,  .{Sign} ),
    instr(.JPE,     ops1(.imm8),                Op1(0x7A),              .I, .RM8,         .{Sign} ),
    instr(.JPE,     ops1(.imm16),               Op2(0x0F, 0x8A),        .I, .RM32Strict,  .{Sign} ),
    instr(.JPE,     ops1(.imm32),               Op2(0x0F, 0x8A),        .I, .RM32Strict,  .{Sign} ),
    instr(.JPO,     ops1(.imm8),                Op1(0x7B),              .I, .RM8,         .{Sign} ),
    instr(.JPO,     ops1(.imm16),               Op2(0x0F, 0x8B),        .I, .RM32Strict,  .{Sign} ),
    instr(.JPO,     ops1(.imm32),               Op2(0x0F, 0x8B),        .I, .RM32Strict,  .{Sign} ),
    instr(.JS,      ops1(.imm8),                Op1(0x78),              .I, .RM8,         .{Sign} ),
    instr(.JS,      ops1(.imm16),               Op2(0x0F, 0x88),        .I, .RM32Strict,  .{Sign} ),
    instr(.JS,      ops1(.imm32),               Op2(0x0F, 0x88),        .I, .RM32Strict,  .{Sign} ),
    instr(.JZ,      ops1(.imm8),                Op1(0x74),              .I, .RM8,         .{Sign} ),
    instr(.JZ,      ops1(.imm16),               Op2(0x0F, 0x84),        .I, .RM32Strict,  .{Sign} ),
    instr(.JZ,      ops1(.imm32),               Op2(0x0F, 0x84),        .I, .RM32Strict,  .{Sign} ),
// JMP
    instr(.JMP,     ops1(.imm8),                Op1(0xEB),              .I, .RM8,         .{Sign} ),
    instr(.JMP,     ops1(.imm16),               Op1(0xE9),              .I, .RM32Strict,  .{Sign} ),
    instr(.JMP,     ops1(.imm32),               Op1(0xE9),              .I, .RM32Strict,  .{Sign} ),
    //
    instr(.JMP,     ops1(.rm16),                Op1r(0xFF, 4),          .M, .RM64Strict,  .{} ),
    instr(.JMP,     ops1(.rm32),                Op1r(0xFF, 4),          .M, .RM64Strict,  .{} ),
    instr(.JMP,     ops1(.rm64),                Op1r(0xFF, 4),          .M, .RM64Strict,  .{} ),
    //
    instr(.JMP,     ops1(.ptr16_16),            Op1r(0xEA, 4),          .D, .RM32Only,    .{} ),
    instr(.JMP,     ops1(.ptr16_32),            Op1r(0xEA, 4),          .D, .RM32Only,    .{} ),
    //
    instr(.JMP,     ops1(.m16_16),              Op1r(0xFF, 5),          .M, .RM32,        .{} ),
    instr(.JMP,     ops1(.m16_32),              Op1r(0xFF, 5),          .M, .RM32,        .{} ),
    instr(.JMP,     ops1(.m16_64),              Op1r(0xFF, 5),          .M, .RM32,        .{} ),
// LAHF
    instr(.LAHF,    ops0(),                     Op1(0x9F),              .ZO, .ZO,         .{cpu.FeatLAHF} ),
// SAHF
    instr(.SAHF,    ops0(),                     Op1(0x9E),              .ZO, .ZO,         .{cpu.FeatLAHF} ),
//  LDS / LSS / LES / LFS / LGS
    instr(.LDS,     ops2(.reg16, .m16_16),      Op1(0xC5),              .RM, .RM32Only,   .{No64} ),
    instr(.LDS,     ops2(.reg32, .m16_32),      Op1(0xC5),              .RM, .RM32Only,   .{No64} ),
    //
    instr(.LSS,     ops2(.reg16, .m16_16),      Op2(0x0F, 0xB2),        .RM, .RM32,       .{_386} ),
    instr(.LSS,     ops2(.reg32, .m16_32),      Op2(0x0F, 0xB2),        .RM, .RM32,       .{_386} ),
    instr(.LSS,     ops2(.reg64, .m16_64),      Op2(0x0F, 0xB2),        .RM, .RM32,       .{x86_64} ),
    //
    instr(.LES,     ops2(.reg16, .m16_16),      Op1(0xC4),              .RM, .RM32Only,   .{No64} ),
    instr(.LES,     ops2(.reg32, .m16_32),      Op1(0xC4),              .RM, .RM32Only,   .{No64} ),
    //
    instr(.LFS,     ops2(.reg16, .m16_16),      Op2(0x0F, 0xB4),        .RM, .RM32,       .{_386} ),
    instr(.LFS,     ops2(.reg32, .m16_32),      Op2(0x0F, 0xB4),        .RM, .RM32,       .{_386} ),
    instr(.LFS,     ops2(.reg64, .m16_64),      Op2(0x0F, 0xB4),        .RM, .RM32,       .{x86_64} ),
    //
    instr(.LGS,     ops2(.reg16, .m16_16),      Op2(0x0F, 0xB5),        .RM, .RM32,       .{_386} ),
    instr(.LGS,     ops2(.reg32, .m16_32),      Op2(0x0F, 0xB5),        .RM, .RM32,       .{_386} ),
    instr(.LGS,     ops2(.reg64, .m16_64),      Op2(0x0F, 0xB5),        .RM, .RM32,       .{x86_64} ),
    //
// LEA
    instr(.LEA,     ops2(.reg16, .rm_mem16),    Op1(0x8D),              .RM, .RM32,       .{} ),
    instr(.LEA,     ops2(.reg32, .rm_mem32),    Op1(0x8D),              .RM, .RM32,       .{} ),
    instr(.LEA,     ops2(.reg64, .rm_mem64),    Op1(0x8D),              .RM, .RM32,       .{} ),
// LEAVE
    instr(.LEAVE,   ops0(),                     Op1(0xC9),              .ZODef, .RM64_16, .{_186} ),
    instr(.LEAVEW,  ops0(),                     Op1(0xC9),              .ZO16,  .RM64_16, .{_186} ),
    instr(.LEAVED,  ops0(),                     Op1(0xC9),              .ZO32,  .RM64_16, .{No64, _186} ),
// LOCK
    instr(.LOCK,    ops0(),                     Op1(0xF0),              .ZO, .ZO,         .{} ),
// LODS / LODSB / LODSW / LODSD / LODSQ
    instr(.LODS,    ops1(._void8),              Op1(0xAC),              .ZO, .RM8,        .{} ),
    instr(.LODS,    ops1(._void),               Op1(0xAD),              .ZO, .RM32,       .{} ),
    //
    instr(.LODSB,   ops0(),                     Op1(0xAC),              .ZO,   .RM8,      .{} ),
    instr(.LODSW,   ops0(),                     Op1(0xAD),              .ZO16, .RM32,     .{} ),
    instr(.LODSD,   ops0(),                     Op1(0xAD),              .ZO32, .RM32,     .{_386} ),
    instr(.LODSQ,   ops0(),                     Op1(0xAD),              .ZO64, .RM32,     .{x86_64} ),
// LOOP
    instr(.LOOP,    ops1(.imm8),                Op1(0xE2),              .I, .RM8,         .{Sign} ),
    instr(.LOOPE,   ops1(.imm8),                Op1(0xE1),              .I, .RM8,         .{Sign} ),
    instr(.LOOPNE,  ops1(.imm8),                Op1(0xE0),              .I, .RM8,         .{Sign} ),
    //
    instr(.LOOPW,   ops1(.imm8),                Op1(0xE2),              .I, .R_Over16,    .{Sign, No64, _386} ),
    instr(.LOOPEW,  ops1(.imm8),                Op1(0xE1),              .I, .R_Over16,    .{Sign, No64, _386} ),
    instr(.LOOPNEW, ops1(.imm8),                Op1(0xE0),              .I, .R_Over16,    .{Sign, No64, _386} ),
    //
    instr(.LOOPD,   ops1(.imm8),                Op1(0xE2),              .I, .R_Over32,    .{Sign, _386} ),
    instr(.LOOPED,  ops1(.imm8),                Op1(0xE1),              .I, .R_Over32,    .{Sign, _386} ),
    instr(.LOOPNED, ops1(.imm8),                Op1(0xE0),              .I, .R_Over32,    .{Sign, _386} ),
// MOV
    instr(.MOV,     ops2(.rm8,  .reg8),         Op1(0x88),              .MR, .RM8,        .{} ),
    instr(.MOV,     ops2(.rm16, .reg16),        Op1(0x89),              .MR, .RM32,       .{} ),
    instr(.MOV,     ops2(.rm32, .reg32),        Op1(0x89),              .MR, .RM32,       .{} ),
    instr(.MOV,     ops2(.rm64, .reg64),        Op1(0x89),              .MR, .RM32,       .{} ),
    //
    instr(.MOV,     ops2(.reg8,  .rm8),         Op1(0x8A),              .RM, .RM8,        .{} ),
    instr(.MOV,     ops2(.reg16, .rm16),        Op1(0x8B),              .RM, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg32, .rm32),        Op1(0x8B),              .RM, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg64, .rm64),        Op1(0x8B),              .RM, .RM32,       .{} ),
    //
    instr(.MOV,     ops2(.rm16, .reg_seg),      Op1(0x8C),              .MR, .RM32_RM,    .{} ),
    instr(.MOV,     ops2(.rm32, .reg_seg),      Op1(0x8C),              .MR, .RM32_RM,    .{} ),
    instr(.MOV,     ops2(.rm64, .reg_seg),      Op1(0x8C),              .MR, .RM32_RM,    .{} ),
    //
    instr(.MOV,     ops2(.reg_seg, .rm16),      Op1(0x8E),              .RM, .RM32_RM,    .{} ),
    instr(.MOV,     ops2(.reg_seg, .rm32),      Op1(0x8E),              .RM, .RM32_RM,    .{} ),
    instr(.MOV,     ops2(.reg_seg, .rm64),      Op1(0x8E),              .RM, .RM32_RM,    .{} ),
    // TODO: CHECK, not 100% sure how moffs is supposed to behave in all cases
    instr(.MOV,     ops2(.reg_al, .moffs8),     Op1(0xA0),              .FD, .RM8,        .{} ),
    instr(.MOV,     ops2(.reg_ax, .moffs16),    Op1(0xA1),              .FD, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg_eax, .moffs32),   Op1(0xA1),              .FD, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg_rax, .moffs64),   Op1(0xA1),              .FD, .RM32,       .{} ),
    instr(.MOV,     ops2(.moffs8, .reg_al),     Op1(0xA2),              .TD, .RM8,        .{} ),
    instr(.MOV,     ops2(.moffs16, .reg_ax),    Op1(0xA3),              .TD, .RM32,       .{} ),
    instr(.MOV,     ops2(.moffs32, .reg_eax),   Op1(0xA3),              .TD, .RM32,       .{} ),
    instr(.MOV,     ops2(.moffs64, .reg_rax),   Op1(0xA3),              .TD, .RM32,       .{} ),
    //
    instr(.MOV,     ops2(.reg8, .imm8),         Op1(0xB0),              .OI, .RM8,        .{} ),
    instr(.MOV,     ops2(.reg16, .imm16),       Op1(0xB8),              .OI, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg32, .imm32),       Op1(0xB8),              .OI, .RM32,       .{} ),
    instr(.MOV,     ops2(.reg64, .imm32),       Op1(0xB8),              .OI, .RM64,       .{NoSign} ),
    instr(.MOV,     ops2(.reg64, .imm64),       Op1(0xB8),              .OI, .RM32,       .{} ),
    //
    instr(.MOV,     ops2(.rm8, .imm8),          Op1r(0xC6, 0),          .MI, .RM8,        .{} ),
    instr(.MOV,     ops2(.rm16, .imm16),        Op1r(0xC7, 0),          .MI, .RM32,       .{} ),
    instr(.MOV,     ops2(.rm32, .imm32),        Op1r(0xC7, 0),          .MI, .RM32,       .{} ),
    instr(.MOV,     ops2(.rm64, .imm32),        Op1r(0xC7, 0),          .MI, .RM32,       .{} ),
    // 386 MOV to/from Control Registers
    instr(.MOV,     ops2(.reg32, .reg_cr),      Op2(0x0F, 0x20),        .MR, .RM32_RM,    .{No64, _386} ),
    instr(.MOV,     ops2(.reg64, .reg_cr),      Op2(0x0F, 0x20),        .MR, .RM64_RM,    .{No32, x86_64} ),
    //
    instr(.MOV,     ops2(.reg_cr, .reg32),      Op2(0x0F, 0x22),        .RM, .RM32_RM,    .{No64, _386} ),
    instr(.MOV,     ops2(.reg_cr, .reg64),      Op2(0x0F, 0x22),        .RM, .RM64_RM,    .{No32, x86_64} ),
    // 386 MOV to/from Debug Registers
    instr(.MOV,     ops2(.reg32, .reg_dr),      Op2(0x0F, 0x21),        .MR, .RM32_RM,    .{No64, _386} ),
    instr(.MOV,     ops2(.reg64, .reg_dr),      Op2(0x0F, 0x21),        .MR, .RM64_RM,    .{No32, x86_64} ),
    //
    instr(.MOV,     ops2(.reg_dr, .reg32),      Op2(0x0F, 0x23),        .RM, .RM32_RM,    .{No64, _386} ),
    instr(.MOV,     ops2(.reg_dr, .reg64),      Op2(0x0F, 0x23),        .RM, .RM64_RM,    .{No32, x86_64} ),
// MOVS / MOVSB / MOVSW / MOVSD / MOVSQ
    instr(.MOVS,    ops1(._void8),              Op1(0xA4),              .ZO, .RM8,        .{} ),
    instr(.MOVS,    ops1(._void),               Op1(0xA5),              .ZO, .RM32,       .{} ),
    //
    instr(.MOVSB,   ops0(),                     Op1(0xA4),              .ZO,   .RM8,      .{} ),
    instr(.MOVSW,   ops0(),                     Op1(0xA5),              .ZO16, .RM32,     .{} ),
    // instr(.MOVSD,   ops0(),                     Op1(0xA5),              .ZO32, .RM32,     .{_386} ), // overloaded
    instr(.MOVSQ,   ops0(),                     Op1(0xA5),              .ZO64, .RM32,     .{x86_64} ),
// MUL
    instr(.MUL,     ops1(.rm8),                 Op1r(0xF6, 4),          .M,  .RM8,        .{} ),
    instr(.MUL,     ops1(.rm16),                Op1r(0xF7, 4),          .M,  .RM32,       .{} ),
    instr(.MUL,     ops1(.rm32),                Op1r(0xF7, 4),          .M,  .RM32,       .{} ),
    instr(.MUL,     ops1(.rm64),                Op1r(0xF7, 4),          .M,  .RM32,       .{} ),
// NEG
    instr(.NEG,     ops1(.rm8),                 Op1r(0xF6, 3),          .M,  .RM8,        .{} ),
    instr(.NEG,     ops1(.rm16),                Op1r(0xF7, 3),          .M,  .RM32,       .{} ),
    instr(.NEG,     ops1(.rm32),                Op1r(0xF7, 3),          .M,  .RM32,       .{} ),
    instr(.NEG,     ops1(.rm64),                Op1r(0xF7, 3),          .M,  .RM32,       .{} ),
// NOP
    instr(.NOP,     ops0(),                     Op1(0x90),              .ZO, .ZO,         .{} ),
    instr(.NOP,     ops1(.rm16),                Op2r(0x0F, 0x1F, 0),    .M,  .RM32,       .{cpu.P6} ),
    instr(.NOP,     ops1(.rm32),                Op2r(0x0F, 0x1F, 0),    .M,  .RM32,       .{cpu.P6} ),
    instr(.NOP,     ops1(.rm64),                Op2r(0x0F, 0x1F, 0),    .M,  .RM32,       .{cpu.P6} ),
// NOT
    instr(.NOT,     ops1(.rm8),                 Op1r(0xF6, 2),          .M,  .RM8,        .{} ),
    instr(.NOT,     ops1(.rm16),                Op1r(0xF7, 2),          .M,  .RM32,       .{} ),
    instr(.NOT,     ops1(.rm32),                Op1r(0xF7, 2),          .M,  .RM32,       .{} ),
    instr(.NOT,     ops1(.rm64),                Op1r(0xF7, 2),          .M,  .RM32,       .{} ),
// OR
    instr(.OR,      ops2(.reg_al, .imm8),       Op1(0x0C),              .I2, .RM8,        .{} ),
    instr(.OR,      ops2(.rm8, .imm8),          Op1r(0x80, 1),          .MI, .RM8,        .{} ),
    instr(.OR,      ops2(.rm16, .imm8),         Op1r(0x83, 1),          .MI, .RM32_I8,    .{Sign} ),
    instr(.OR,      ops2(.rm32, .imm8),         Op1r(0x83, 1),          .MI, .RM32_I8,    .{Sign} ),
    instr(.OR,      ops2(.rm64, .imm8),         Op1r(0x83, 1),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.OR,      ops2(.reg_ax, .imm16),      Op1(0x0D),              .I2, .RM32,       .{} ),
    instr(.OR,      ops2(.reg_eax, .imm32),     Op1(0x0D),              .I2, .RM32,       .{} ),
    instr(.OR,      ops2(.reg_rax, .imm32),     Op1(0x0D),              .I2, .RM32,       .{Sign} ),
    //
    instr(.OR,      ops2(.rm16, .imm16),        Op1r(0x81, 1),          .MI, .RM32,       .{} ),
    instr(.OR,      ops2(.rm32, .imm32),        Op1r(0x81, 1),          .MI, .RM32,       .{} ),
    instr(.OR,      ops2(.rm64, .imm32),        Op1r(0x81, 1),          .MI, .RM32,       .{Sign} ),
    //
    instr(.OR,      ops2(.rm8, .reg8),          Op1(0x08),              .MR, .RM8,        .{} ),
    instr(.OR,      ops2(.rm16, .reg16),        Op1(0x09),              .MR, .RM32,       .{} ),
    instr(.OR,      ops2(.rm32, .reg32),        Op1(0x09),              .MR, .RM32,       .{} ),
    instr(.OR,      ops2(.rm64, .reg64),        Op1(0x09),              .MR, .RM32,       .{} ),
    //
    instr(.OR,      ops2(.reg8, .rm8),          Op1(0x0A),              .RM, .RM8,        .{} ),
    instr(.OR,      ops2(.reg16, .rm16),        Op1(0x0B),              .RM, .RM32,       .{} ),
    instr(.OR,      ops2(.reg32, .rm32),        Op1(0x0B),              .RM, .RM32,       .{} ),
    instr(.OR,      ops2(.reg64, .rm64),        Op1(0x0B),              .RM, .RM32,       .{} ),
// OUT
    instr(.OUT,     ops2(.imm8, .reg_al),       Op1(0xE6),              .I, .ZO,          .{} ),
    instr(.OUT,     ops2(.imm8, .reg_ax),       Op1(0xE7),              .I, .RM32,        .{} ),
    instr(.OUT,     ops2(.imm8, .reg_eax),      Op1(0xE7),              .I, .RM32,        .{} ),
    instr(.OUT,     ops2(.reg_dx, .reg_al),     Op1(0xEE),              .ZO, .ZO,         .{} ),
    instr(.OUT,     ops2(.reg_dx, .reg_ax),     Op1(0xEF),              .ZO16, .RM32,     .{} ),
    instr(.OUT,     ops2(.reg_dx, .reg_eax),    Op1(0xEF),              .ZO32, .RM32,     .{} ),
// OUTS / OUTSB / OUTSW / OUTSD
    instr(.OUTS,    ops1(._void8),              Op1(0x6E),              .ZO, .RM8,        .{_186} ),
    instr(.OUTS,    ops1(._void),               Op1(0x6F),              .ZO, .RM32,       .{_186} ),
    //
    instr(.OUTSB,   ops0(),                     Op1(0x6E),              .ZO,   .RM8,      .{_186} ),
    instr(.OUTSW,   ops0(),                     Op1(0x6F),              .ZO16, .RM32,     .{_186} ),
    instr(.OUTSD,   ops0(),                     Op1(0x6F),              .ZO32, .RM32,     .{_386} ),
// POP
    instr(.POP,     ops1(.reg16),               Op1(0x58),              .O,  .RM64_16,    .{} ),
    instr(.POP,     ops1(.reg32),               Op1(0x58),              .O,  .RM64_16,    .{} ),
    instr(.POP,     ops1(.reg64),               Op1(0x58),              .O,  .RM64_16,    .{} ),
    //
    instr(.POP,     ops1(.rm16),                Op1r(0x8F, 0),          .M,  .RM64_16,    .{} ),
    instr(.POP,     ops1(.rm32),                Op1r(0x8F, 0),          .M,  .RM64_16,    .{} ),
    instr(.POP,     ops1(.rm64),                Op1r(0x8F, 0),          .M,  .RM64_16,    .{} ),
    //
    instr(.POP,     ops1(.reg_ds),              Op1(0x1F),              .ZODef, .ZO32Only,.{} ),
    instr(.POP,     ops1(.reg_es),              Op1(0x07),              .ZODef, .ZO32Only,.{} ),
    instr(.POP,     ops1(.reg_ss),              Op1(0x17),              .ZODef, .ZO32Only,.{} ),
    instr(.POP,     ops1(.reg_fs),              Op2(0x0F, 0xA1),        .ZO, .ZO,         .{} ),
    instr(.POP,     ops1(.reg_gs),              Op2(0x0F, 0xA9),        .ZO, .ZO,         .{} ),
    //
    instr(.POPW,    ops1(.reg_ds),              Op1(0x1F),              .ZO16, .ZO32Only, .{} ),
    instr(.POPW,    ops1(.reg_es),              Op1(0x07),              .ZO16, .ZO32Only, .{} ),
    instr(.POPW,    ops1(.reg_ss),              Op1(0x17),              .ZO16, .ZO32Only, .{} ),
    instr(.POPW,    ops1(.reg_fs),              Op2(0x0F, 0xA1),        .ZO16, .ZO64_16,  .{} ),
    instr(.POPW,    ops1(.reg_gs),              Op2(0x0F, 0xA9),        .ZO16, .ZO64_16,  .{} ),
    //
    instr(.POPD,    ops1(.reg_ds),              Op1(0x1F),              .ZO32, .ZO32Only, .{No64} ),
    instr(.POPD,    ops1(.reg_es),              Op1(0x07),              .ZO32, .ZO32Only, .{No64} ),
    instr(.POPD,    ops1(.reg_ss),              Op1(0x17),              .ZO32, .ZO32Only, .{No64} ),
    instr(.POPD,    ops1(.reg_fs),              Op2(0x0F, 0xA1),        .ZO32, .ZO64_16,  .{No64} ),
    instr(.POPD,    ops1(.reg_gs),              Op2(0x0F, 0xA9),        .ZO32, .ZO64_16,  .{No64} ),
    //
    instr(.POPQ,    ops1(.reg_ds),              Op1(0x1F),              .ZO64, .ZO32Only, .{No32} ),
    instr(.POPQ,    ops1(.reg_es),              Op1(0x07),              .ZO64, .ZO32Only, .{No32} ),
    instr(.POPQ,    ops1(.reg_ss),              Op1(0x17),              .ZO64, .ZO32Only, .{No32} ),
    instr(.POPQ,    ops1(.reg_fs),              Op2(0x0F, 0xA1),        .ZO64, .ZO64_16,  .{No32} ),
    instr(.POPQ,    ops1(.reg_gs),              Op2(0x0F, 0xA9),        .ZO64, .ZO64_16,  .{No32} ),
// POPA
    instr(.POPA,    ops0(),                     Op1(0x60),              .ZODef, .RM32,    .{No64, _186} ),
    instr(.POPAW,   ops0(),                     Op1(0x60),              .ZO16,  .RM32,    .{No64, _186} ),
    instr(.POPAD,   ops0(),                     Op1(0x60),              .ZO32,  .RM32,    .{No64, _386} ),
// POPF / POPFD / POPFQ
    instr(.POPF,    ops1(._void),               Op1(0x9D),              .ZO, .RM64_16,    .{} ),
    //
    instr(.POPF,    ops0(),                     Op1(0x9D),              .ZODef, .RM64_16, .{} ),
    instr(.POPFW,   ops0(),                     Op1(0x9D),              .ZO16,  .RM64_16, .{} ),
    instr(.POPFD,   ops0(),                     Op1(0x9D),              .ZO32,  .RM32Only,.{_386} ),
    instr(.POPFQ,   ops0(),                     Op1(0x9D),              .ZO64,  .RM64_16, .{x86_64} ),
// PUSH
    instr(.PUSH,    ops1(.imm8),                Op1(0x6A),              .I,  .RM8 ,       .{_186} ),
    instr(.PUSH,    ops1(.imm16),               Op1(0x68),              .I,  .RM32,       .{_186} ),
    instr(.PUSH,    ops1(.imm32),               Op1(0x68),              .I,  .RM32,       .{_386} ),
    //
    instr(.PUSH,    ops1(.reg16),               Op1(0x50),              .O,  .RM64_16,    .{} ),
    instr(.PUSH,    ops1(.reg32),               Op1(0x50),              .O,  .RM64_16,    .{} ),
    instr(.PUSH,    ops1(.reg64),               Op1(0x50),              .O,  .RM64_16,    .{} ),
    //
    instr(.PUSH,    ops1(.rm16),                Op1r(0xFF, 6),          .M,  .RM64_16,    .{} ),
    instr(.PUSH,    ops1(.rm32),                Op1r(0xFF, 6),          .M,  .RM64_16,    .{} ),
    instr(.PUSH,    ops1(.rm64),                Op1r(0xFF, 6),          .M,  .RM64_16,    .{} ),
    //
    instr(.PUSH,    ops1(.reg_cs),              Op1(0x0E),              .ZODef, .ZO32Only,.{} ),
    instr(.PUSH,    ops1(.reg_ss),              Op1(0x16),              .ZODef, .ZO32Only,.{} ),
    instr(.PUSH,    ops1(.reg_ds),              Op1(0x1E),              .ZODef, .ZO32Only,.{} ),
    instr(.PUSH,    ops1(.reg_es),              Op1(0x06),              .ZODef, .ZO32Only,.{} ),
    instr(.PUSH,    ops1(.reg_fs),              Op2(0x0F, 0xA0),        .ZO, .ZO,         .{} ),
    instr(.PUSH,    ops1(.reg_gs),              Op2(0x0F, 0xA8),        .ZO, .ZO,         .{} ),
    //
    instr(.PUSHW,   ops1(.reg_cs),              Op1(0x0E),              .ZO16, .ZO32Only, .{} ),
    instr(.PUSHW,   ops1(.reg_ss),              Op1(0x16),              .ZO16, .ZO32Only, .{} ),
    instr(.PUSHW,   ops1(.reg_ds),              Op1(0x1E),              .ZO16, .ZO32Only, .{} ),
    instr(.PUSHW,   ops1(.reg_es),              Op1(0x06),              .ZO16, .ZO32Only, .{} ),
    instr(.PUSHW,   ops1(.reg_fs),              Op2(0x0F, 0xA0),        .ZO16, .ZO64_16,  .{} ),
    instr(.PUSHW,   ops1(.reg_gs),              Op2(0x0F, 0xA8),        .ZO16, .ZO64_16,  .{} ),
    //
    instr(.PUSHD,   ops1(.reg_cs),              Op1(0x0E),              .ZO32, .ZO32Only, .{No64} ),
    instr(.PUSHD,   ops1(.reg_ss),              Op1(0x16),              .ZO32, .ZO32Only, .{No64} ),
    instr(.PUSHD,   ops1(.reg_ds),              Op1(0x1E),              .ZO32, .ZO32Only, .{No64} ),
    instr(.PUSHD,   ops1(.reg_es),              Op1(0x06),              .ZO32, .ZO32Only, .{No64} ),
    instr(.PUSHD,   ops1(.reg_fs),              Op2(0x0F, 0xA0),        .ZO32, .ZO64_16,  .{No64} ),
    instr(.PUSHD,   ops1(.reg_gs),              Op2(0x0F, 0xA8),        .ZO32, .ZO64_16,  .{No64} ),
    //
    instr(.PUSHQ,   ops1(.reg_cs),              Op1(0x0E),              .ZO64, .ZO32Only, .{No32} ),
    instr(.PUSHQ,   ops1(.reg_ss),              Op1(0x16),              .ZO64, .ZO32Only, .{No32} ),
    instr(.PUSHQ,   ops1(.reg_ds),              Op1(0x1E),              .ZO64, .ZO32Only, .{No32} ),
    instr(.PUSHQ,   ops1(.reg_es),              Op1(0x06),              .ZO64, .ZO32Only, .{No32} ),
    instr(.PUSHQ,   ops1(.reg_fs),              Op2(0x0F, 0xA0),        .ZO64, .ZO64_16,  .{No32} ),
    instr(.PUSHQ,   ops1(.reg_gs),              Op2(0x0F, 0xA8),        .ZO64, .ZO64_16,  .{No32} ),
// PUSHA
    instr(.PUSHA,   ops0(),                     Op1(0x60),              .ZODef, .RM32,    .{No64, _186} ),
    instr(.PUSHAW,  ops0(),                     Op1(0x60),              .ZO16,  .RM32,    .{No64, _186} ),
    instr(.PUSHAD,  ops0(),                     Op1(0x60),              .ZO32,  .RM32,    .{No64, _386} ),
// PUSHF / PUSHFW / PUSHFD / PUSHFQ
    instr(.PUSHF,    ops1(._void),              Op1(0x9C),              .ZO, .RM64_16,    .{} ),
    //
    instr(.PUSHF,    ops0(),                    Op1(0x9C),              .ZODef, .RM64_16, .{} ),
    instr(.PUSHFW,   ops0(),                    Op1(0x9C),              .ZO16,  .RM64_16, .{} ),
    instr(.PUSHFD,   ops0(),                    Op1(0x9C),              .ZODef, .RM32Only,.{_386} ),
    instr(.PUSHFQ,   ops0(),                    Op1(0x9C),              .ZO64,  .RM64_16, .{x86_64} ),
//  RCL / RCR / ROL / ROR
    instr(.RCL,     ops2(.rm8, .imm_1),         Op1r(0xD0, 2),          .M,  .RM8,        .{} ),
    instr(.RCL,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 2),          .M,  .RM8,        .{} ),
    instr(.RCL,     ops2(.rm8,  .imm8),         Op1r(0xC0, 2),          .MI, .RM8,        .{_186} ),
    instr(.RCL,     ops2(.rm16, .imm_1),        Op1r(0xD1, 2),          .M,  .RM32_I8,    .{} ),
    instr(.RCL,     ops2(.rm32, .imm_1),        Op1r(0xD1, 2),          .M,  .RM32_I8,    .{} ),
    instr(.RCL,     ops2(.rm64, .imm_1),        Op1r(0xD1, 2),          .M,  .RM32_I8,    .{} ),
    instr(.RCL,     ops2(.rm16, .imm8),         Op1r(0xC1, 2),          .MI, .RM32_I8,    .{_186} ),
    instr(.RCL,     ops2(.rm32, .imm8),         Op1r(0xC1, 2),          .MI, .RM32_I8,    .{_386} ),
    instr(.RCL,     ops2(.rm64, .imm8),         Op1r(0xC1, 2),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.RCL,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 2),          .M,  .RM32,       .{} ),
    instr(.RCL,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 2),          .M,  .RM32,       .{} ),
    instr(.RCL,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 2),          .M,  .RM32,       .{} ),
    //
    instr(.RCR,     ops2(.rm8, .imm_1),         Op1r(0xD0, 3),          .M,  .RM8,        .{} ),
    instr(.RCR,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 3),          .M,  .RM8,        .{} ),
    instr(.RCR,     ops2(.rm8,  .imm8),         Op1r(0xC0, 3),          .MI, .RM8,        .{_186} ),
    instr(.RCR,     ops2(.rm16, .imm_1),        Op1r(0xD1, 3),          .M,  .RM32_I8,    .{} ),
    instr(.RCR,     ops2(.rm32, .imm_1),        Op1r(0xD1, 3),          .M,  .RM32_I8,    .{} ),
    instr(.RCR,     ops2(.rm64, .imm_1),        Op1r(0xD1, 3),          .M,  .RM32_I8,    .{} ),
    instr(.RCR,     ops2(.rm16, .imm8),         Op1r(0xC1, 3),          .MI, .RM32_I8,    .{_186} ),
    instr(.RCR,     ops2(.rm32, .imm8),         Op1r(0xC1, 3),          .MI, .RM32_I8,    .{_386} ),
    instr(.RCR,     ops2(.rm64, .imm8),         Op1r(0xC1, 3),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.RCR,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 3),          .M,  .RM32,       .{} ),
    instr(.RCR,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 3),          .M,  .RM32,       .{} ),
    instr(.RCR,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 3),          .M,  .RM32,       .{} ),
    //
    instr(.ROL,     ops2(.rm8, .imm_1),         Op1r(0xD0, 0),          .M,  .RM8,        .{} ),
    instr(.ROL,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 0),          .M,  .RM8,        .{} ),
    instr(.ROL,     ops2(.rm8,  .imm8),         Op1r(0xC0, 0),          .MI, .RM8,        .{_186} ),
    instr(.ROL,     ops2(.rm16, .imm_1),        Op1r(0xD1, 0),          .M,  .RM32_I8,    .{} ),
    instr(.ROL,     ops2(.rm32, .imm_1),        Op1r(0xD1, 0),          .M,  .RM32_I8,    .{} ),
    instr(.ROL,     ops2(.rm64, .imm_1),        Op1r(0xD1, 0),          .M,  .RM32_I8,    .{} ),
    instr(.ROL,     ops2(.rm16, .imm8),         Op1r(0xC1, 0),          .MI, .RM32_I8,    .{_186} ),
    instr(.ROL,     ops2(.rm32, .imm8),         Op1r(0xC1, 0),          .MI, .RM32_I8,    .{_386} ),
    instr(.ROL,     ops2(.rm64, .imm8),         Op1r(0xC1, 0),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.ROL,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 0),          .M,  .RM32,       .{} ),
    instr(.ROL,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 0),          .M,  .RM32,       .{} ),
    instr(.ROL,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 0),          .M,  .RM32,       .{} ),
    //
    instr(.ROR,     ops2(.rm8, .imm_1),         Op1r(0xD0, 1),          .M,  .RM8,        .{} ),
    instr(.ROR,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 1),          .M,  .RM8,        .{} ),
    instr(.ROR,     ops2(.rm8,  .imm8),         Op1r(0xC0, 1),          .MI, .RM8,        .{_186} ),
    instr(.ROR,     ops2(.rm16, .imm_1),        Op1r(0xD1, 1),          .M,  .RM32_I8,    .{} ),
    instr(.ROR,     ops2(.rm32, .imm_1),        Op1r(0xD1, 1),          .M,  .RM32_I8,    .{} ),
    instr(.ROR,     ops2(.rm64, .imm_1),        Op1r(0xD1, 1),          .M,  .RM32_I8,    .{} ),
    instr(.ROR,     ops2(.rm16, .imm8),         Op1r(0xC1, 1),          .MI, .RM32_I8,    .{_186} ),
    instr(.ROR,     ops2(.rm32, .imm8),         Op1r(0xC1, 1),          .MI, .RM32_I8,    .{_386} ),
    instr(.ROR,     ops2(.rm64, .imm8),         Op1r(0xC1, 1),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.ROR,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 1),          .M,  .RM32,       .{} ),
    instr(.ROR,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 1),          .M,  .RM32,       .{} ),
    instr(.ROR,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 1),          .M,  .RM32,       .{} ),
// REP / REPE / REPZ / REPNE / REPNZ
    instr(.REP,     ops0(),                     Op1(0xF3),              .ZO, .ZO,         .{} ),
    instr(.REPE,    ops0(),                     Op1(0xF3),              .ZO, .ZO,         .{} ),
    instr(.REPZ,    ops0(),                     Op1(0xF3),              .ZO, .ZO,         .{} ),
    instr(.REPNE,   ops0(),                     Op1(0xF2),              .ZO, .ZO,         .{} ),
    instr(.REPNZ,   ops0(),                     Op1(0xF2),              .ZO, .ZO,         .{} ),
//  RET
    instr(.RET,     ops0(),                     Op1(0xC3),              .ZO, .ZO,         .{} ),
    instr(.RET,     ops1(.imm16),               Op1(0xC2),              .I,  .RM16,       .{} ),
//  RETF
    instr(.RETF,    ops0(),                     Op1(0xCB),              .ZO, .ZO,         .{} ),
    instr(.RETF,    ops1(.imm16),               Op1(0xCA),              .I,  .RM16,       .{} ),
//  RETN
    instr(.RETN,    ops0(),                     Op1(0xC3),              .ZO, .ZO,         .{} ),
    instr(.RETN,    ops1(.imm16),               Op1(0xC2),              .I,  .RM16,       .{} ),
//  SAL / SAR / SHL / SHR
    instr(.SAL,     ops2(.rm8, .imm_1),         Op1r(0xD0, 4),          .M,  .RM8,        .{} ),
    instr(.SAL,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 4),          .M,  .RM8,        .{} ),
    instr(.SAL,     ops2(.rm8,  .imm8),         Op1r(0xC0, 4),          .MI, .RM8,        .{_186} ),
    instr(.SAL,     ops2(.rm16, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SAL,     ops2(.rm32, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SAL,     ops2(.rm64, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SAL,     ops2(.rm16, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{_186} ),
    instr(.SAL,     ops2(.rm32, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{_386} ),
    instr(.SAL,     ops2(.rm64, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.SAL,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    instr(.SAL,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    instr(.SAL,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    //
    instr(.SAR,     ops2(.rm8, .imm_1),         Op1r(0xD0, 7),          .M,  .RM8,        .{} ),
    instr(.SAR,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 7),          .M,  .RM8,        .{} ),
    instr(.SAR,     ops2(.rm8,  .imm8),         Op1r(0xC0, 7),          .MI, .RM8,        .{_186} ),
    instr(.SAR,     ops2(.rm16, .imm_1),        Op1r(0xD1, 7),          .M,  .RM32_I8,    .{} ),
    instr(.SAR,     ops2(.rm32, .imm_1),        Op1r(0xD1, 7),          .M,  .RM32_I8,    .{} ),
    instr(.SAR,     ops2(.rm64, .imm_1),        Op1r(0xD1, 7),          .M,  .RM32_I8,    .{} ),
    instr(.SAR,     ops2(.rm16, .imm8),         Op1r(0xC1, 7),          .MI, .RM32_I8,    .{_186} ),
    instr(.SAR,     ops2(.rm32, .imm8),         Op1r(0xC1, 7),          .MI, .RM32_I8,    .{_386} ),
    instr(.SAR,     ops2(.rm64, .imm8),         Op1r(0xC1, 7),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.SAR,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 7),          .M,  .RM32,       .{} ),
    instr(.SAR,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 7),          .M,  .RM32,       .{} ),
    instr(.SAR,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 7),          .M,  .RM32,       .{} ),
    //
    instr(.SHL,     ops2(.rm8, .imm_1),         Op1r(0xD0, 4),          .M,  .RM8,        .{} ),
    instr(.SHL,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 4),          .M,  .RM8,        .{} ),
    instr(.SHL,     ops2(.rm8,  .imm8),         Op1r(0xC0, 4),          .MI, .RM8,        .{_186} ),
    instr(.SHL,     ops2(.rm16, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SHL,     ops2(.rm32, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SHL,     ops2(.rm64, .imm_1),        Op1r(0xD1, 4),          .M,  .RM32_I8,    .{} ),
    instr(.SHL,     ops2(.rm16, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{_186} ),
    instr(.SHL,     ops2(.rm32, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{_386} ),
    instr(.SHL,     ops2(.rm64, .imm8),         Op1r(0xC1, 4),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.SHL,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    instr(.SHL,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    instr(.SHL,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 4),          .M,  .RM32,       .{} ),
    //
    instr(.SHR,     ops2(.rm8, .imm_1),         Op1r(0xD0, 5),          .M,  .RM8,        .{} ),
    instr(.SHR,     ops2(.rm8, .reg_cl),        Op1r(0xD2, 5),          .M,  .RM8,        .{} ),
    instr(.SHR,     ops2(.rm8,  .imm8),         Op1r(0xC0, 5),          .MI, .RM8,        .{_186} ),
    instr(.SHR,     ops2(.rm16, .imm_1),        Op1r(0xD1, 5),          .M,  .RM32_I8,    .{} ),
    instr(.SHR,     ops2(.rm32, .imm_1),        Op1r(0xD1, 5),          .M,  .RM32_I8,    .{} ),
    instr(.SHR,     ops2(.rm64, .imm_1),        Op1r(0xD1, 5),          .M,  .RM32_I8,    .{} ),
    instr(.SHR,     ops2(.rm16, .imm8),         Op1r(0xC1, 5),          .MI, .RM32_I8,    .{_186} ),
    instr(.SHR,     ops2(.rm32, .imm8),         Op1r(0xC1, 5),          .MI, .RM32_I8,    .{_386} ),
    instr(.SHR,     ops2(.rm64, .imm8),         Op1r(0xC1, 5),          .MI, .RM32_I8,    .{x86_64} ),
    instr(.SHR,     ops2(.rm16, .reg_cl),       Op1r(0xD3, 5),          .M,  .RM32,       .{} ),
    instr(.SHR,     ops2(.rm32, .reg_cl),       Op1r(0xD3, 5),          .M,  .RM32,       .{} ),
    instr(.SHR,     ops2(.rm64, .reg_cl),       Op1r(0xD3, 5),          .M,  .RM32,       .{} ),
// SBB
    instr(.SBB,     ops2(.reg_al, .imm8),       Op1(0x1C),              .I2, .RM8,        .{} ),
    instr(.SBB,     ops2(.rm8, .imm8),          Op1r(0x80, 3),          .MI, .RM8,        .{} ),
    instr(.SBB,     ops2(.rm16, .imm8),         Op1r(0x83, 3),          .MI, .RM32_I8,    .{Sign} ),
    instr(.SBB,     ops2(.rm32, .imm8),         Op1r(0x83, 3),          .MI, .RM32_I8,    .{Sign} ),
    instr(.SBB,     ops2(.rm64, .imm8),         Op1r(0x83, 3),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.SBB,     ops2(.reg_ax, .imm16),      Op1(0x1D),              .I2, .RM32,       .{} ),
    instr(.SBB,     ops2(.reg_eax, .imm32),     Op1(0x1D),              .I2, .RM32,       .{} ),
    instr(.SBB,     ops2(.reg_rax, .imm32),     Op1(0x1D),              .I2, .RM32,       .{Sign} ),
    //
    instr(.SBB,     ops2(.rm16, .imm16),        Op1r(0x81, 3),          .MI, .RM32,       .{} ),
    instr(.SBB,     ops2(.rm32, .imm32),        Op1r(0x81, 3),          .MI, .RM32,       .{} ),
    instr(.SBB,     ops2(.rm64, .imm32),        Op1r(0x81, 3),          .MI, .RM32,       .{Sign} ),
    //
    instr(.SBB,     ops2(.rm8, .reg8),          Op1(0x18),              .MR, .RM8,        .{} ),
    instr(.SBB,     ops2(.rm16, .reg16),        Op1(0x19),              .MR, .RM32,       .{} ),
    instr(.SBB,     ops2(.rm32, .reg32),        Op1(0x19),              .MR, .RM32,       .{} ),
    instr(.SBB,     ops2(.rm64, .reg64),        Op1(0x19),              .MR, .RM32,       .{} ),
    //
    instr(.SBB,     ops2(.reg8, .rm8),          Op1(0x1A),              .RM, .RM8,        .{} ),
    instr(.SBB,     ops2(.reg16, .rm16),        Op1(0x1B),              .RM, .RM32,       .{} ),
    instr(.SBB,     ops2(.reg32, .rm32),        Op1(0x1B),              .RM, .RM32,       .{} ),
    instr(.SBB,     ops2(.reg64, .rm64),        Op1(0x1B),              .RM, .RM32,       .{} ),
// SCAS / SCASB / SCASW / SCASD / SCASQ
    instr(.SCAS,    ops1(._void8),              Op1(0xAE),              .ZO, .RM8,        .{} ),
    instr(.SCAS,    ops1(._void),               Op1(0xAF),              .ZO, .RM32,       .{} ),
    //
    instr(.SCASB,   ops0(),                     Op1(0xAE),              .ZO,   .RM8,      .{} ),
    instr(.SCASW,   ops0(),                     Op1(0xAF),              .ZO16, .RM32,     .{} ),
    instr(.SCASD,   ops0(),                     Op1(0xAF),              .ZO32, .RM32,     .{_386} ),
    instr(.SCASQ,   ops0(),                     Op1(0xAF),              .ZO64, .RM32,     .{x86_64} ),
// STC
    instr(.STC,     ops0(),                     Op1(0xF9),              .ZO, .ZO,         .{} ),
// STD
    instr(.STD,     ops0(),                     Op1(0xFD),              .ZO, .ZO,         .{} ),
// STI
    instr(.STI,     ops0(),                     Op1(0xFB),              .ZO, .ZO,         .{} ),
// STOS / STOSB / STOSW / STOSD / STOSQ
    instr(.STOS,    ops1(._void8),              Op1(0xAA),              .ZO, .RM8,        .{} ),
    instr(.STOS,    ops1(._void),               Op1(0xAB),              .ZO, .RM32,       .{} ),
    //
    instr(.STOSB,   ops0(),                     Op1(0xAA),              .ZO,   .RM8,      .{} ),
    instr(.STOSW,   ops0(),                     Op1(0xAB),              .ZO16, .RM32,     .{} ),
    instr(.STOSD,   ops0(),                     Op1(0xAB),              .ZO32, .RM32,     .{_386} ),
    instr(.STOSQ,   ops0(),                     Op1(0xAB),              .ZO64, .RM32,     .{x86_64} ),
// SUB
    instr(.SUB,     ops2(.reg_al, .imm8),       Op1(0x2C),              .I2, .RM8,        .{} ),
    instr(.SUB,     ops2(.rm8, .imm8),          Op1r(0x80, 5),          .MI, .RM8,        .{} ),
    instr(.SUB,     ops2(.rm16, .imm8),         Op1r(0x83, 5),          .MI, .RM32_I8,    .{Sign} ),
    instr(.SUB,     ops2(.rm32, .imm8),         Op1r(0x83, 5),          .MI, .RM32_I8,    .{Sign} ),
    instr(.SUB,     ops2(.rm64, .imm8),         Op1r(0x83, 5),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.SUB,     ops2(.reg_ax, .imm16),      Op1(0x2D),              .I2, .RM32,       .{} ),
    instr(.SUB,     ops2(.reg_eax, .imm32),     Op1(0x2D),              .I2, .RM32,       .{} ),
    instr(.SUB,     ops2(.reg_rax, .imm32),     Op1(0x2D),              .I2, .RM32,       .{Sign} ),
    //
    instr(.SUB,     ops2(.rm16, .imm16),        Op1r(0x81, 5),          .MI, .RM32,       .{} ),
    instr(.SUB,     ops2(.rm32, .imm32),        Op1r(0x81, 5),          .MI, .RM32,       .{} ),
    instr(.SUB,     ops2(.rm64, .imm32),        Op1r(0x81, 5),          .MI, .RM32,       .{Sign} ),
    //
    instr(.SUB,     ops2(.rm8, .reg8),          Op1(0x28),              .MR, .RM8,        .{} ),
    instr(.SUB,     ops2(.rm16, .reg16),        Op1(0x29),              .MR, .RM32,       .{} ),
    instr(.SUB,     ops2(.rm32, .reg32),        Op1(0x29),              .MR, .RM32,       .{} ),
    instr(.SUB,     ops2(.rm64, .reg64),        Op1(0x29),              .MR, .RM32,       .{} ),
    //
    instr(.SUB,     ops2(.reg8, .rm8),          Op1(0x2A),              .RM, .RM8,        .{} ),
    instr(.SUB,     ops2(.reg16, .rm16),        Op1(0x2B),              .RM, .RM32,       .{} ),
    instr(.SUB,     ops2(.reg32, .rm32),        Op1(0x2B),              .RM, .RM32,       .{} ),
    instr(.SUB,     ops2(.reg64, .rm64),        Op1(0x2B),              .RM, .RM32,       .{} ),
// TEST
    instr(.TEST,    ops2(.reg_al, .imm8),       Op1(0xA8),              .I2, .RM8,        .{} ),
    instr(.TEST,    ops2(.reg_ax, .imm16),      Op1(0xA9),              .I2, .RM32,       .{} ),
    instr(.TEST,    ops2(.reg_eax, .imm32),     Op1(0xA9),              .I2, .RM32,       .{} ),
    instr(.TEST,    ops2(.reg_rax, .imm32),     Op1(0xA9),              .I2, .RM32,       .{Sign} ),
    //
    instr(.TEST,    ops2(.rm8, .imm8),          Op1r(0xF6, 0),          .MI, .RM8,        .{} ),
    instr(.TEST,    ops2(.rm16, .imm16),        Op1r(0xF7, 0),          .MI, .RM32,       .{} ),
    instr(.TEST,    ops2(.rm32, .imm32),        Op1r(0xF7, 0),          .MI, .RM32,       .{} ),
    instr(.TEST,    ops2(.rm64, .imm32),        Op1r(0xF7, 0),          .MI, .RM32,       .{} ),
    //
    instr(.TEST,    ops2(.rm8,  .reg8),         Op1(0x84),              .MR, .RM8,        .{} ),
    instr(.TEST,    ops2(.rm16, .reg16),        Op1(0x85),              .MR, .RM32,       .{} ),
    instr(.TEST,    ops2(.rm32, .reg32),        Op1(0x85),              .MR, .RM32,       .{} ),
    instr(.TEST,    ops2(.rm64, .reg64),        Op1(0x85),              .MR, .RM32,       .{} ),
// WAIT
    instr(.WAIT,    ops0(),                     Op1(0x9B),              .ZO, .ZO,         .{} ),
// XCHG
    instr(.XCHG,    ops2(.reg_ax, .reg16),      Op1(0x90),              .O2, .RM32,       .{} ),
    instr(.XCHG,    ops2(.reg16, .reg_ax),      Op1(0x90),              .O,  .RM32,       .{} ),
    instr(.XCHG,    ops2(.reg_eax, .reg32),     Op1(0x90),              .O2, .RM32,       .{edge.XCHG_EAX} ),
    instr(.XCHG,    ops2(.reg32, .reg_eax),     Op1(0x90),              .O,  .RM32,       .{edge.XCHG_EAX} ),
    instr(.XCHG,    ops2(.reg_rax, .reg64),     Op1(0x90),              .O2, .RM32,       .{} ),
    instr(.XCHG,    ops2(.reg64, .reg_rax),     Op1(0x90),              .O,  .RM32,       .{} ),
    //
    instr(.XCHG,    ops2(.rm8, .reg8),          Op1(0x86),              .MR, .RM8,        .{pre.Lock} ),
    instr(.XCHG,    ops2(.reg8, .rm8),          Op1(0x86),              .RM, .RM8,        .{pre.Lock} ),
    instr(.XCHG,    ops2(.rm16, .reg16),        Op1(0x87),              .MR, .RM32,       .{pre.Lock} ),
    instr(.XCHG,    ops2(.reg16, .rm16),        Op1(0x87),              .RM, .RM32,       .{pre.Lock} ),
    instr(.XCHG,    ops2(.rm32, .reg32),        Op1(0x87),              .MR, .RM32,       .{pre.Lock} ),
    instr(.XCHG,    ops2(.reg32, .rm32),        Op1(0x87),              .RM, .RM32,       .{pre.Lock} ),
    instr(.XCHG,    ops2(.rm64, .reg64),        Op1(0x87),              .MR, .RM32,       .{pre.Lock} ),
    instr(.XCHG,    ops2(.reg64, .rm64),        Op1(0x87),              .RM, .RM32,       .{pre.Lock} ),
// XLAT / XLATB
    instr(.XLAT,    ops1(._void),               Op1(0xD7),              .ZO, .RM32,       .{} ),
    //
    instr(.XLAT,    ops0(),                     Op1(0xD7),              .ZO, .ZO,         .{} ),
    instr(.XLATB,   ops0(),                     Op1(0xD7),              .ZO, .ZO,         .{} ),
    // instr(.XLATB,   ops0(),                     Op1(0xD7),              .ZO64, .RM32,     .{} ),
// XOR
    instr(.XOR,     ops2(.reg_al, .imm8),       Op1(0x34),              .I2, .RM8,        .{} ),
    instr(.XOR,     ops2(.rm8, .imm8),          Op1r(0x80, 6),          .MI, .RM8,        .{} ),
    instr(.XOR,     ops2(.rm16, .imm8),         Op1r(0x83, 6),          .MI, .RM32_I8,    .{Sign} ),
    instr(.XOR,     ops2(.rm32, .imm8),         Op1r(0x83, 6),          .MI, .RM32_I8,    .{Sign} ),
    instr(.XOR,     ops2(.rm64, .imm8),         Op1r(0x83, 6),          .MI, .RM32_I8,    .{Sign} ),
    //
    instr(.XOR,     ops2(.reg_ax, .imm16),      Op1(0x35),              .I2, .RM32,       .{} ),
    instr(.XOR,     ops2(.reg_eax, .imm32),     Op1(0x35),              .I2, .RM32,       .{} ),
    instr(.XOR,     ops2(.reg_rax, .imm32),     Op1(0x35),              .I2, .RM32,       .{Sign} ),
    //
    instr(.XOR,     ops2(.rm16, .imm16),        Op1r(0x81, 6),          .MI, .RM32,       .{} ),
    instr(.XOR,     ops2(.rm32, .imm32),        Op1r(0x81, 6),          .MI, .RM32,       .{} ),
    instr(.XOR,     ops2(.rm64, .imm32),        Op1r(0x81, 6),          .MI, .RM32,       .{Sign} ),
    //
    instr(.XOR,     ops2(.rm8, .reg8),          Op1(0x30),              .MR, .RM8,        .{} ),
    instr(.XOR,     ops2(.rm16, .reg16),        Op1(0x31),              .MR, .RM32,       .{} ),
    instr(.XOR,     ops2(.rm32, .reg32),        Op1(0x31),              .MR, .RM32,       .{} ),
    instr(.XOR,     ops2(.rm64, .reg64),        Op1(0x31),              .MR, .RM32,       .{} ),
    //
    instr(.XOR,     ops2(.reg8, .rm8),          Op1(0x32),              .RM, .RM8,        .{} ),
    instr(.XOR,     ops2(.reg16, .rm16),        Op1(0x33),              .RM, .RM32,       .{} ),
    instr(.XOR,     ops2(.reg32, .rm32),        Op1(0x33),              .RM, .RM32,       .{} ),
    instr(.XOR,     ops2(.reg64, .rm64),        Op1(0x33),              .RM, .RM32,       .{} ),
//
// x87 -- 8087 / 80287 / 80387
//

// F2XM1
    instr(.F2XM1,   ops0(),                   Op2(0xD9, 0xF0),       .ZO, .ZO,    .{_087} ),
// FABS
    instr(.FABS,    ops0(),                   Op2(0xD9, 0xE1),       .ZO, .ZO,    .{_087} ),
// FADD / FADDP / FIADD
    instr(.FADD,    ops1(.rm_mem32),          Op1r(0xD8, 0),         .M, .ZO,     .{_087} ),
    instr(.FADD,    ops1(.rm_mem64),          Op1r(0xDC, 0),         .M, .ZO,     .{_087} ),
    instr(.FADD,    ops1(.reg_st),            Op2(0xD8, 0xC0),       .O, .ZO,     .{_087} ),
    instr(.FADD,    ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xC0),       .O, .ZO,     .{_087} ),
    instr(.FADD,    ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xC0),       .O2, .ZO,    .{_087} ),
    //
    instr(.FADDP,   ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xC0),       .O, .ZO,     .{_087} ),
    instr(.FADDP,   ops0(),                   Op2(0xDE, 0xC1),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FIADD,   ops1(.rm_mem16),          Op1r(0xDE, 0),         .M, .ZO,     .{_087} ),
    instr(.FIADD,   ops1(.rm_mem32),          Op1r(0xDA, 0),         .M, .ZO,     .{_087} ),
// FBLD
    instr(.FBLD,    ops1(.rm_mem80),          Op1r(0xDF, 4),         .M, .ZO,     .{_087} ),
// FBSTP
    instr(.FBSTP,   ops1(.rm_mem80),          Op1r(0xDF, 6),         .M, .ZO,     .{_087} ),
// FCHS
    instr(.FCHS,    ops0(),                   Op2(0xD9, 0xE0),       .ZO, .ZO,    .{_087} ),
    instr(.FCHS,    ops1(.reg_st0),           Op2(0xD9, 0xE0),       .ZO, .ZO,    .{_087} ),
// FCLEX / FNCLEX
    instr(.FCLEX,   ops0(),               compOp2(0x9B, 0xDB, 0xE2), .ZO, .ZO,    .{_087} ),
    instr(.FNCLEX,  ops0(),                   Op2(0xDB, 0xE2),       .ZO, .ZO,    .{_087} ),
// FCOM / FCOMP / FCOMPP
    instr(.FCOM,    ops1(.rm_mem32),          Op1r(0xD8, 2),         .M, .ZO,     .{_087} ),
    instr(.FCOM,    ops1(.rm_mem64),          Op1r(0xDC, 2),         .M, .ZO,     .{_087} ),
    //
    instr(.FCOM,    ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xD0),       .O2, .ZO,    .{_087} ),
    instr(.FCOM,    ops1(.reg_st),            Op2(0xD8, 0xD0),       .O,  .ZO,    .{_087} ),
    instr(.FCOM,    ops0(),                   Op2(0xD8, 0xD1),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FCOMP,   ops1(.rm_mem32),          Op1r(0xD8, 3),         .M, .ZO,     .{_087} ),
    instr(.FCOMP,   ops1(.rm_mem64),          Op1r(0xDC, 3),         .M, .ZO,     .{_087} ),
    //
    instr(.FCOMP,   ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xD8),       .O2, .ZO,    .{_087} ),
    instr(.FCOMP,   ops1(.reg_st),            Op2(0xD8, 0xD8),       .O,  .ZO,    .{_087} ),
    instr(.FCOMP,   ops0(),                   Op2(0xD8, 0xD9),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FCOMPP,  ops0(),                   Op2(0xDE, 0xD9),       .ZO, .ZO,    .{_087} ),
// FDECSTP
    instr(.FDECSTP, ops0(),                   Op2(0xD9, 0xF6),       .ZO, .ZO,    .{_087} ),
// FDIV / FDIVP / FIDIV
    instr(.FDIV,    ops1(.rm_mem32),          Op1r(0xD8, 6),         .M, .ZO,     .{_087} ),
    instr(.FDIV,    ops1(.rm_mem64),          Op1r(0xDC, 6),         .M, .ZO,     .{_087} ),
    //
    instr(.FDIV,    ops1(.reg_st),            Op2(0xD8, 0xF0),       .O,  .ZO,    .{_087} ),
    instr(.FDIV,    ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xF0),       .O2, .ZO,    .{_087} ),
    instr(.FDIV,    ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xF8),       .O,  .ZO,    .{_087} ),
    //
    instr(.FDIVP,   ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xF8),       .O,  .ZO,    .{_087} ),
    instr(.FDIVP,   ops0(),                   Op2(0xDE, 0xF9),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FIDIV,   ops1(.rm_mem16),          Op1r(0xDE, 6),         .M, .ZO,     .{_087} ),
    instr(.FIDIV,   ops1(.rm_mem32),          Op1r(0xDA, 6),         .M, .ZO,     .{_087} ),
// FDIVR / FDIVRP / FIDIVR
    instr(.FDIVR,   ops1(.rm_mem32),          Op1r(0xD8, 7),         .M, .ZO,     .{_087} ),
    instr(.FDIVR,   ops1(.rm_mem64),          Op1r(0xDC, 7),         .M, .ZO,     .{_087} ),
    //
    instr(.FDIVR,   ops1(.reg_st),            Op2(0xD8, 0xF8),       .O,  .ZO,    .{_087} ),
    instr(.FDIVR,   ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xF0),       .O,  .ZO,    .{_087} ),
    instr(.FDIVR,   ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xF8),       .O2, .ZO,    .{_087} ),
    //
    instr(.FDIVRP,  ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xF0),       .O,  .ZO,    .{_087} ),
    instr(.FDIVRP,  ops0(),                   Op2(0xDE, 0xF1),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FIDIVR,  ops1(.rm_mem16),          Op1r(0xDE, 7),         .M, .ZO,     .{_087} ),
    instr(.FIDIVR,  ops1(.rm_mem32),          Op1r(0xDA, 7),         .M, .ZO,     .{_087} ),
// FFREE
    instr(.FFREE,   ops1(.reg_st),            Op2(0xDD, 0xC0),       .O,  .ZO,    .{_087} ),
// FICOM / FICOMP
    instr(.FICOM,   ops1(.rm_mem16),          Op1r(0xDE, 2),         .M, .ZO,     .{_087} ),
    instr(.FICOM,   ops1(.rm_mem32),          Op1r(0xDA, 2),         .M, .ZO,     .{_087} ),
    //
    instr(.FICOMP,  ops1(.rm_mem16),          Op1r(0xDE, 3),         .M, .ZO,     .{_087} ),
    instr(.FICOMP,  ops1(.rm_mem32),          Op1r(0xDA, 3),         .M, .ZO,     .{_087} ),
// FILD
    instr(.FILD,    ops1(.rm_mem16),          Op1r(0xDF, 0),         .M, .ZO,     .{_087} ),
    instr(.FILD,    ops1(.rm_mem32),          Op1r(0xDB, 0),         .M, .ZO,     .{_087} ),
    instr(.FILD,    ops1(.rm_mem64),          Op1r(0xDF, 5),         .M, .ZO,     .{_087} ),
// FINCSTP
    instr(.FINCSTP, ops0(),                   Op2(0xD9, 0xF7),       .ZO, .ZO,    .{_087} ),
// FINIT / FNINIT
    instr(.FINIT,   ops0(),               compOp2(0x9B, 0xDB, 0xE3), .ZO, .ZO,    .{_087} ),
    instr(.FNINIT,  ops0(),                   Op2(0xDB, 0xE3),       .ZO, .ZO,    .{_087} ),
// FIST
    instr(.FIST,    ops1(.rm_mem16),          Op1r(0xDF, 2),         .M, .ZO,     .{_087} ),
    instr(.FIST,    ops1(.rm_mem32),          Op1r(0xDB, 2),         .M, .ZO,     .{_087} ),
    //
    instr(.FISTP,   ops1(.rm_mem16),          Op1r(0xDF, 3),         .M, .ZO,     .{_087} ),
    instr(.FISTP,   ops1(.rm_mem32),          Op1r(0xDB, 3),         .M, .ZO,     .{_087} ),
    instr(.FISTP,   ops1(.rm_mem64),          Op1r(0xDF, 7),         .M, .ZO,     .{_087} ),
// FLD
    instr(.FLD,     ops1(.rm_mem32),          Op1r(0xD9, 0),         .M, .ZO,     .{_087} ),
    instr(.FLD,     ops1(.rm_mem64),          Op1r(0xDD, 0),         .M, .ZO,     .{_087} ),
    instr(.FLD,     ops1(.rm_mem80),          Op1r(0xDB, 5),         .M, .ZO,     .{_087} ),
    instr(.FLD,     ops1(.reg_st),            Op2(0xD9, 0xC0),       .O, .ZO,     .{_087} ),
    instr(.FLDCW,   ops1(.rm_mem16),          Op1r(0xD9, 5),         .M, .ZO,     .{_087} ),
    instr(.FLDCW,   ops1(.rm_mem),            Op1r(0xD9, 5),         .M, .ZO,     .{_087} ),
    instr(.FLD1,    ops0(),                   Op2(0xD9, 0xE8),       .ZO, .ZO,    .{_087} ),
    instr(.FLDL2T,  ops0(),                   Op2(0xD9, 0xE9),       .ZO, .ZO,    .{_087} ),
    instr(.FLDL2E,  ops0(),                   Op2(0xD9, 0xEA),       .ZO, .ZO,    .{_087} ),
    instr(.FLDPI,   ops0(),                   Op2(0xD9, 0xEB),       .ZO, .ZO,    .{_087} ),
    instr(.FLDLG2,  ops0(),                   Op2(0xD9, 0xEC),       .ZO, .ZO,    .{_087} ),
    instr(.FLDLN2,  ops0(),                   Op2(0xD9, 0xED),       .ZO, .ZO,    .{_087} ),
    instr(.FLDZ,    ops0(),                   Op2(0xD9, 0xEE),       .ZO, .ZO,    .{_087} ),
// FLDENV
    instr(.FLDENV,  ops1(.rm_mem),            Op1r(0xD9, 4),         .M, .ZO,     .{_087} ),
// FMUL / FMULP / FIMUL
    instr(.FMUL,    ops1(.rm_mem32),          Op1r(0xD8, 1),         .M, .ZO,     .{_087} ),
    instr(.FMUL,    ops1(.rm_mem64),          Op1r(0xDC, 1),         .M, .ZO,     .{_087} ),
    //
    instr(.FMUL,    ops1(.reg_st),            Op2(0xD8, 0xC8),       .O,  .ZO,    .{_087} ),
    instr(.FMUL,    ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xC8),       .O,  .ZO,    .{_087} ),
    instr(.FMUL,    ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xC8),       .O2, .ZO,    .{_087} ),
    //
    instr(.FMULP,   ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xC8),       .O,  .ZO,    .{_087} ),
    instr(.FMULP,   ops0(),                   Op2(0xDE, 0xC9),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FIMUL,   ops1(.rm_mem16),          Op1r(0xDE, 1),         .M, .ZO,     .{_087} ),
    instr(.FIMUL,   ops1(.rm_mem32),          Op1r(0xDA, 1),         .M, .ZO,     .{_087} ),
// FNOP
    instr(.FNOP,    ops0(),                   Op2(0xD9, 0xD0),       .ZO, .ZO,    .{_087} ),
// FPATAN
    instr(.FPATAN,  ops0(),                   Op2(0xD9, 0xF3),       .ZO, .ZO,    .{_087} ),
// FPREM
    instr(.FPREM,   ops0(),                   Op2(0xD9, 0xF8),       .ZO, .ZO,    .{_087} ),
// FPTAN
    instr(.FPTAN,   ops0(),                   Op2(0xD9, 0xF2),       .ZO, .ZO,    .{_087} ),
// FRNDINT
    instr(.FRNDINT, ops0(),                   Op2(0xD9, 0xFC),       .ZO, .ZO,    .{_087} ),
// FRSTOR
    instr(.FRSTOR,  ops1(.rm_mem),            Op1r(0xDD, 4),         .M, .ZO,     .{_087} ),
// FSAVE / FNSAVE
    instr(.FSAVE,   ops1(.rm_mem),        compOp1r(0x9B, 0xDD, 6),   .M, .ZO,     .{_087} ),
    instr(.FNSAVE,  ops1(.rm_mem),            Op1r(0xDD, 6),         .M, .ZO,     .{_087} ),
// FSCALE
    instr(.FSCALE,  ops0(),                   Op2(0xD9, 0xFD),       .ZO, .ZO,    .{_087} ),
// FSQRT
    instr(.FSQRT,   ops0(),                   Op2(0xD9, 0xFA),       .ZO, .ZO,    .{_087} ),
// FST / FSTP
    instr(.FST,     ops1(.rm_mem32),          Op1r(0xD9, 2),         .M, .ZO,     .{_087} ),
    instr(.FST,     ops1(.rm_mem64),          Op1r(0xDD, 2),         .M, .ZO,     .{_087} ),
    instr(.FST,     ops1(.reg_st),            Op2(0xDD, 0xD0),       .O, .ZO,     .{_087} ),
    instr(.FST,     ops2(.reg_st0, .reg_st),  Op2(0xDD, 0xD0),       .O2, .ZO,    .{_087} ),
    instr(.FSTP,    ops1(.rm_mem32),          Op1r(0xD9, 3),         .M, .ZO,     .{_087} ),
    instr(.FSTP,    ops1(.rm_mem64),          Op1r(0xDD, 3),         .M, .ZO,     .{_087} ),
    instr(.FSTP,    ops1(.rm_mem80),          Op1r(0xDB, 7),         .M, .ZO,     .{_087} ),
    instr(.FSTP,    ops1(.reg_st),            Op2(0xDD, 0xD8),       .O, .ZO,     .{_087} ),
    instr(.FSTP,    ops2(.reg_st0, .reg_st),  Op2(0xDD, 0xD8),       .O2, .ZO,    .{_087} ),
// FSTCW / FNSTCW
    instr(.FSTCW,   ops1(.rm_mem),        compOp1r(0x9B, 0xD9, 7),   .M, .ZO,     .{_087} ),
    instr(.FSTCW,   ops1(.rm_mem16),      compOp1r(0x9B, 0xD9, 7),   .M, .ZO,     .{_087} ),
    instr(.FNSTCW,  ops1(.rm_mem),            Op1r(0xD9, 7),         .M, .ZO,     .{_087} ),
    instr(.FNSTCW,  ops1(.rm_mem16),          Op1r(0xD9, 7),         .M, .ZO,     .{_087} ),
// FSTENV / FNSTENV
    instr(.FSTENV,  ops1(.rm_mem),        compOp1r(0x9B, 0xD9, 6),   .M, .ZO,     .{_087} ),
    instr(.FNSTENV, ops1(.rm_mem),            Op1r(0xD9, 6),         .M, .ZO,     .{_087} ),
// FSTSW / FNSTSW
    instr(.FSTSW,   ops1(.rm_mem),        compOp1r(0x9B, 0xDD, 7),   .M, .ZO,     .{_087} ),
    instr(.FSTSW,   ops1(.rm_mem16),      compOp1r(0x9B, 0xDD, 7),   .M, .ZO,     .{_087} ),
    instr(.FSTSW,   ops1(.reg_ax),        compOp2(0x9B, 0xDF, 0xE0), .ZO, .ZO,    .{_087} ),
    instr(.FNSTSW,  ops1(.rm_mem),            Op1r(0xDD, 7),         .M, .ZO,     .{_087} ),
    instr(.FNSTSW,  ops1(.rm_mem16),          Op1r(0xDD, 7),         .M, .ZO,     .{_087} ),
    instr(.FNSTSW,  ops1(.reg_ax),            Op2(0xDF, 0xE0),       .ZO, .ZO,    .{_087} ),
// FSUB / FSUBP / FISUB
    instr(.FSUB,    ops1(.rm_mem32),          Op1r(0xD8, 4),         .M, .ZO,     .{_087} ),
    instr(.FSUB,    ops1(.rm_mem64),          Op1r(0xDC, 4),         .M, .ZO,     .{_087} ),
    //
    instr(.FSUB,    ops1(.reg_st),            Op2(0xD8, 0xE0),       .O,  .ZO,    .{_087} ),
    instr(.FSUB,    ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xE8),       .O,  .ZO,    .{_087} ),
    instr(.FSUB,    ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xE0),       .O2, .ZO,    .{_087} ),
    //
    instr(.FSUBP,   ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xE8),       .O,  .ZO,    .{_087} ),
    instr(.FSUBP,   ops0(),                   Op2(0xDE, 0xE9),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FISUB,   ops1(.rm_mem16),          Op1r(0xDE, 4),         .M, .ZO,     .{_087} ),
    instr(.FISUB,   ops1(.rm_mem32),          Op1r(0xDA, 4),         .M, .ZO,     .{_087} ),
// FSUBR / FSUBRP / FISUBR
    instr(.FSUBR,   ops1(.rm_mem32),          Op1r(0xD8, 5),         .M, .ZO,     .{_087} ),
    instr(.FSUBR,   ops1(.rm_mem64),          Op1r(0xDC, 5),         .M, .ZO,     .{_087} ),
    //
    instr(.FSUBR,   ops1(.reg_st),            Op2(0xD8, 0xE8),       .O,  .ZO,    .{_087} ),
    instr(.FSUBR,   ops2(.reg_st0, .reg_st),  Op2(0xD8, 0xE8),       .O2, .ZO,    .{_087} ),
    instr(.FSUBR,   ops2(.reg_st, .reg_st0),  Op2(0xDC, 0xE0),       .O,  .ZO,    .{_087} ),
    //
    instr(.FSUBRP,  ops2(.reg_st, .reg_st0),  Op2(0xDE, 0xE0),       .O,  .ZO,    .{_087} ),
    instr(.FSUBRP,  ops0(),                   Op2(0xDE, 0xE1),       .ZO, .ZO,    .{_087} ),
    //
    instr(.FISUBR,  ops1(.rm_mem16),          Op1r(0xDE, 5),         .M, .ZO,     .{_087} ),
    instr(.FISUBR,  ops1(.rm_mem32),          Op1r(0xDA, 5),         .M, .ZO,     .{_087} ),
// FTST
    instr(.FTST,    ops0(),                   Op2(0xD9, 0xE4),       .ZO, .ZO,    .{_087} ),
// FWAIT (alternate mnemonic for WAIT)
    instr(.FWAIT,   ops0(),                   Op1(0x9B),             .ZO, .ZO,    .{_087} ),
// FXAM
    instr(.FXAM,    ops0(),                   Op2(0xD9, 0xE5),       .ZO, .ZO,    .{_087} ),
// FXCH
    instr(.FXCH,    ops2(.reg_st0, .reg_st),  Op2(0xD9, 0xC8),       .O2, .ZO,    .{_087} ),
    instr(.FXCH,    ops1(.reg_st),            Op2(0xD9, 0xC8),       .O, .ZO,     .{_087} ),
    instr(.FXCH,    ops0(),                   Op2(0xD9, 0xC9),       .ZO, .ZO,    .{_087} ),
// FXTRACT
    instr(.FXTRACT, ops0(),                   Op2(0xD9, 0xF4),       .ZO, .ZO,    .{_087} ),
// FYL2X
    instr(.FYL2X,   ops0(),                   Op2(0xD9, 0xF1),       .ZO, .ZO,    .{_087} ),
// FYL2XP1
    instr(.FYL2XP1, ops0(),                   Op2(0xD9, 0xF9),       .ZO, .ZO,    .{_087} ),

//
// 80287
//
    // instr(.FSETPM,  ops0(),                   Op2(0xDB, 0xE4),       .ZO, .ZO,    .{cpu._287, edge.obsolete} ),

//
// 80387
//
    instr(.FCOS,    ops0(),                   Op2(0xD9, 0xFF),       .ZO, .ZO,    .{_387} ),
    instr(.FPREM1,  ops0(),                   Op2(0xD9, 0xF5),       .ZO, .ZO,    .{_387} ),
    instr(.FSIN,    ops0(),                   Op2(0xD9, 0xFE),       .ZO, .ZO,    .{_387} ),
    instr(.FSINCOS, ops0(),                   Op2(0xD9, 0xFB),       .ZO, .ZO,    .{_387} ),
// FUCOM / FUCOMP / FUCOMPP
    instr(.FUCOM,   ops2(.reg_st0, .reg_st),  Op2(0xDD, 0xE0),       .O2, .ZO,    .{_387} ),
    instr(.FUCOM,   ops1(.reg_st),            Op2(0xDD, 0xE0),       .O,  .ZO,    .{_387} ),
    instr(.FUCOM,   ops0(),                   Op2(0xDD, 0xE1),       .ZO, .ZO,    .{_387} ),
    //
    instr(.FUCOMP,  ops2(.reg_st0, .reg_st),  Op2(0xDD, 0xE8),       .O2, .ZO,    .{_387} ),
    instr(.FUCOMP,  ops1(.reg_st),            Op2(0xDD, 0xE8),       .O,  .ZO,    .{_387} ),
    instr(.FUCOMP,  ops0(),                   Op2(0xDD, 0xE9),       .ZO, .ZO,    .{_387} ),
    //
    instr(.FUCOMPP, ops0(),                   Op2(0xDA, 0xE9),       .ZO, .ZO,    .{_387} ),
    //
    // TODO: need to also handle:
    // * FLDENVW
    // * FSAVEW
    // * FRSTORW
    // * FSTENVW
    // * FLDENVD
    // * FSAVED
    // * FRSTORD
    // * FSTENVD

//
// x87 -- Pentium Pro / P6
//
// FCMOVcc
    instr(.FCMOVB,   ops2(.reg_st0, .reg_st),  Op2(0xDA, 0xC0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVB,   ops1(.reg_st),            Op2(0xDA, 0xC0),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVE,   ops2(.reg_st0, .reg_st),  Op2(0xDA, 0xC8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVE,   ops1(.reg_st),            Op2(0xDA, 0xC8),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVBE,  ops2(.reg_st0, .reg_st),  Op2(0xDA, 0xD0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVBE,  ops1(.reg_st),            Op2(0xDA, 0xD0),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVU,   ops2(.reg_st0, .reg_st),  Op2(0xDA, 0xD8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVU,   ops1(.reg_st),            Op2(0xDA, 0xD8),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVNB,  ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xC0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVNB,  ops1(.reg_st),            Op2(0xDB, 0xC0),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVNE,  ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xC8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVNE,  ops1(.reg_st),            Op2(0xDB, 0xC8),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVNBE, ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xD0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVNBE, ops1(.reg_st),            Op2(0xDB, 0xD0),       .O,  .ZO,    .{cpu.P6} ),
    //
    instr(.FCMOVNU,  ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xD8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCMOVNU,  ops1(.reg_st),            Op2(0xDB, 0xD8),       .O,  .ZO,    .{cpu.P6} ),
// FCOMI
    instr(.FCOMI,    ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xF0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCOMI,    ops1(.reg_st),            Op2(0xDB, 0xF0),       .O,  .ZO,    .{cpu.P6} ),
// FCOMIP
    instr(.FCOMIP,   ops2(.reg_st0, .reg_st),  Op2(0xDF, 0xF0),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FCOMIP,   ops1(.reg_st),            Op2(0xDF, 0xF0),       .O,  .ZO,    .{cpu.P6} ),
// FUCOMI
    instr(.FUCOMI,   ops2(.reg_st0, .reg_st),  Op2(0xDB, 0xE8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FUCOMI,   ops1(.reg_st),            Op2(0xDB, 0xE8),       .O,  .ZO,    .{cpu.P6} ),
// FUCOMIP
    instr(.FUCOMIP,  ops2(.reg_st0, .reg_st),  Op2(0xDF, 0xE8),       .O2, .ZO,    .{cpu.P6} ),
    instr(.FUCOMIP,  ops1(.reg_st),            Op2(0xDF, 0xE8),       .O,  .ZO,    .{cpu.P6} ),

//
//  x87 - other
// FFREEP - undocumented instruction, present since 80286
    instr(.FFREEP,   ops1(.reg_st),            Op2(0xDF, 0xC0),       .O, .ZO,     .{_287} ),
// FISTTP
    instr(.FISTTP,   ops1(.rm_mem16),          Op1r(0xDF, 1),         .M, .ZO,     .{SSE3} ),
    instr(.FISTTP,   ops1(.rm_mem32),          Op1r(0xDB, 1),         .M, .ZO,     .{SSE3} ),
    instr(.FISTTP,   ops1(.rm_mem64),          Op1r(0xDD, 1),         .M, .ZO,     .{SSE3} ),

//
// 80286
//
    // NOTES: might want to handle operands like `r32/m16` better
    instr(.ARPL,    ops2(.rm16, .reg16),        Op1(0x63),              .MR, .RM16,       .{No64, _286} ),
    //
    instr(.CLTS,    ops0(),                     Op2(0x0F, 0x06),        .ZO, .ZO,         .{_286} ),
    //
    instr(.LAR,     ops2(.reg16, .rm16),        Op2(0x0F, 0x02),        .RM, .RM32,       .{_286} ),
    instr(.LAR,     ops2(.reg32, .rm32),        Op2(0x0F, 0x02),        .RM, .RM32,       .{_386} ),
    instr(.LAR,     ops2(.reg64, .rm64),        Op2(0x0F, 0x02),        .RM, .RM32,       .{x86_64} ),
    //
    instr(.LGDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 2),    .M,  .ZO,         .{No64, _286} ),
    instr(.LGDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 2),    .M,  .ZO,         .{No32, _286} ),
    //
    instr(.LIDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 3),    .M,  .ZO,         .{No64, _286} ),
    instr(.LIDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 3),    .M,  .ZO,         .{No32, _286} ),
    //
    instr(.LLDT,    ops1(.rm16),                Op2r(0x0F, 0x00, 2),    .M,  .RM16,       .{_286} ),
    //
    instr(.LMSW,    ops1(.rm16),                Op2r(0x0F, 0x01, 6),    .M,  .RM16,       .{_286} ),
    //
    // instr(.LOADALL, ops1(.rm16),                Op2r(0x0F, 0x01, 6),    .M, .RM16,        .{_286, _386} ), // undocumented
    //
    instr(.LSL,     ops2(.reg16, .rm16),        Op2(0x0F, 0x03),        .RM, .RM32,       .{_286} ),
    instr(.LSL,     ops2(.reg32, .rm32),        Op2(0x0F, 0x03),        .RM, .RM32,       .{_386} ),
    instr(.LSL,     ops2(.reg64, .rm64),        Op2(0x0F, 0x03),        .RM, .RM32,       .{x86_64} ),
    //
    instr(.LTR,     ops1(.rm16),                Op2r(0x0F, 0x00, 3),    .M,  .RM16,       .{_286} ),
    //
    instr(.SGDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 0),    .M,  .ZO,         .{_286} ),
    //
    instr(.SIDT,    ops1(.rm_mem),              Op2r(0x0F, 0x01, 1),    .M,  .ZO,         .{_286} ),
    //
    instr(.SLDT,    ops1(.rm_mem16),            Op2r(0x0F, 0x00, 0),    .M,  .RM16,       .{_286} ),
    instr(.SLDT,    ops1(.rm_reg16),            Op2r(0x0F, 0x00, 0),    .M,  .RM32,       .{_286} ),
    instr(.SLDT,    ops1(.reg16),               Op2r(0x0F, 0x00, 0),    .M,  .RM32,       .{_286} ),
    instr(.SLDT,    ops1(.reg32),               Op2r(0x0F, 0x00, 0),    .M,  .RM32,       .{_386} ),
    instr(.SLDT,    ops1(.reg64),               Op2r(0x0F, 0x00, 0),    .M,  .RM32,       .{x86_64} ),
    //
    instr(.SMSW,    ops1(.rm_mem16),            Op2r(0x0F, 0x01, 4),    .M,  .RM16,       .{_286} ),
    instr(.SMSW,    ops1(.rm_reg16),            Op2r(0x0F, 0x01, 4),    .M,  .RM32,       .{_286} ),
    instr(.SMSW,    ops1(.reg16),               Op2r(0x0F, 0x01, 4),    .M,  .RM32,       .{_286} ),
    instr(.SMSW,    ops1(.reg32),               Op2r(0x0F, 0x01, 4),    .M,  .RM32,       .{_386} ),
    instr(.SMSW,    ops1(.reg64),               Op2r(0x0F, 0x01, 4),    .M,  .RM32,       .{x86_64} ),
    //
    instr(.STR,     ops1(.rm_mem16),            Op2r(0x0F, 0x00, 1),    .M,  .RM16,       .{_286} ),
    instr(.STR,     ops1(.rm_reg16),            Op2r(0x0F, 0x00, 1),    .M,  .RM32,       .{_286} ),
    instr(.STR,     ops1(.reg16),               Op2r(0x0F, 0x00, 1),    .M,  .RM32,       .{_286} ),
    instr(.STR,     ops1(.reg32),               Op2r(0x0F, 0x00, 1),    .M,  .RM32,       .{_386} ),
    instr(.STR,     ops1(.reg64),               Op2r(0x0F, 0x00, 1),    .M,  .RM32,       .{x86_64} ),
    //
    instr(.VERR,    ops1(.rm16),                Op2r(0x0F, 0x00, 4),    .M,  .RM16,       .{_286} ),
    instr(.VERW,    ops1(.rm16),                Op2r(0x0F, 0x00, 5),    .M,  .RM16,       .{_286} ),

//
// 80386
//
// BSF
    instr(.BSF,     ops2(.reg16, .rm16),        Op2(0x0F, 0xBC),        .RM, .RM32,       .{_386} ),
    instr(.BSF,     ops2(.reg32, .rm32),        Op2(0x0F, 0xBC),        .RM, .RM32,       .{_386} ),
    instr(.BSF,     ops2(.reg64, .rm64),        Op2(0x0F, 0xBC),        .RM, .RM32,       .{x86_64} ),
// BSR
    instr(.BSR,     ops2(.reg16, .rm16),        Op2(0x0F, 0xBD),        .RM, .RM32,       .{_386} ),
    instr(.BSR,     ops2(.reg32, .rm32),        Op2(0x0F, 0xBD),        .RM, .RM32,       .{_386} ),
    instr(.BSR,     ops2(.reg64, .rm64),        Op2(0x0F, 0xBD),        .RM, .RM32,       .{x86_64} ),
// BSR
    instr(.BT,      ops2(.rm16, .reg16),        Op2(0x0F, 0xA3),        .MR, .RM32,       .{_386} ),
    instr(.BT,      ops2(.rm32, .reg32),        Op2(0x0F, 0xA3),        .MR, .RM32,       .{_386} ),
    instr(.BT,      ops2(.rm64, .reg64),        Op2(0x0F, 0xA3),        .MR, .RM32,       .{x86_64} ),
    //
    instr(.BT,      ops2(.rm16, .imm8),         Op2r(0x0F, 0xBA, 4),    .MI, .RM32_I8,    .{_386} ),
    instr(.BT,      ops2(.rm32, .imm8),         Op2r(0x0F, 0xBA, 4),    .MI, .RM32_I8,    .{_386} ),
    instr(.BT,      ops2(.rm64, .imm8),         Op2r(0x0F, 0xBA, 4),    .MI, .RM32_I8,    .{x86_64} ),
// BTC
    instr(.BTC,     ops2(.rm16, .reg16),        Op2(0x0F, 0xBB),        .MR, .RM32,       .{_386} ),
    instr(.BTC,     ops2(.rm32, .reg32),        Op2(0x0F, 0xBB),        .MR, .RM32,       .{_386} ),
    instr(.BTC,     ops2(.rm64, .reg64),        Op2(0x0F, 0xBB),        .MR, .RM32,       .{x86_64} ),
    //
    instr(.BTC,     ops2(.rm16, .imm8),         Op2r(0x0F, 0xBA, 7),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTC,     ops2(.rm32, .imm8),         Op2r(0x0F, 0xBA, 7),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTC,     ops2(.rm64, .imm8),         Op2r(0x0F, 0xBA, 7),    .MI, .RM32_I8,    .{x86_64} ),
// BTR
    instr(.BTR,     ops2(.rm16, .reg16),        Op2(0x0F, 0xB3),        .MR, .RM32,       .{_386} ),
    instr(.BTR,     ops2(.rm32, .reg32),        Op2(0x0F, 0xB3),        .MR, .RM32,       .{_386} ),
    instr(.BTR,     ops2(.rm64, .reg64),        Op2(0x0F, 0xB3),        .MR, .RM32,       .{x86_64} ),
    //
    instr(.BTR,     ops2(.rm16, .imm8),         Op2r(0x0F, 0xBA, 6),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTR,     ops2(.rm32, .imm8),         Op2r(0x0F, 0xBA, 6),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTR,     ops2(.rm64, .imm8),         Op2r(0x0F, 0xBA, 6),    .MI, .RM32_I8,    .{x86_64} ),
// BTS
    instr(.BTS,     ops2(.rm16, .reg16),        Op2(0x0F, 0xAB),        .MR, .RM32,       .{_386} ),
    instr(.BTS,     ops2(.rm32, .reg32),        Op2(0x0F, 0xAB),        .MR, .RM32,       .{_386} ),
    instr(.BTS,     ops2(.rm64, .reg64),        Op2(0x0F, 0xAB),        .MR, .RM32,       .{x86_64} ),
    //
    instr(.BTS,     ops2(.rm16, .imm8),         Op2r(0x0F, 0xBA, 5),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTS,     ops2(.rm32, .imm8),         Op2r(0x0F, 0xBA, 5),    .MI, .RM32_I8,    .{_386} ),
    instr(.BTS,     ops2(.rm64, .imm8),         Op2r(0x0F, 0xBA, 5),    .MI, .RM32_I8,    .{x86_64} ),
// MOVSX / MOVSXD
    instr(.MOVSX,   ops2(.reg16, .rm8),         Op2(0x0F, 0xBE),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSX,   ops2(.reg32, .rm8),         Op2(0x0F, 0xBE),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSX,   ops2(.reg64, .rm8),         Op2(0x0F, 0xBE),        .RM, .RM32_Reg,    .{x86_64} ),
    //
    instr(.MOVSX,   ops2(.reg16, .rm16),        Op2(0x0F, 0xBF),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSX,   ops2(.reg32, .rm16),        Op2(0x0F, 0xBF),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSX,   ops2(.reg64, .rm16),        Op2(0x0F, 0xBF),        .RM, .RM32_Reg,    .{x86_64} ),
    //
    instr(.MOVSXD,  ops2(.reg16, .rm16),        Op1(0x63),              .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSXD,  ops2(.reg16, .rm32),        Op1(0x63),              .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSXD,  ops2(.reg32, .rm32),        Op1(0x63),              .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVSXD,  ops2(.reg64, .rm32),        Op1(0x63),              .RM, .RM32_Reg,    .{x86_64} ),
// MOVZX
    instr(.MOVZX,   ops2(.reg16, .rm8),         Op2(0x0F, 0xB6),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVZX,   ops2(.reg32, .rm8),         Op2(0x0F, 0xB6),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVZX,   ops2(.reg64, .rm8),         Op2(0x0F, 0xB6),        .RM, .RM32_Reg,    .{x86_64} ),
    //
    instr(.MOVZX,   ops2(.reg16, .rm16),        Op2(0x0F, 0xB7),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVZX,   ops2(.reg32, .rm16),        Op2(0x0F, 0xB7),        .RM, .RM32_Reg,    .{_386} ),
    instr(.MOVZX,   ops2(.reg64, .rm16),        Op2(0x0F, 0xB7),        .RM, .RM32_Reg,    .{x86_64} ),
// SETcc
    instr(.SETA,    ops1(.rm8),                 Op2(0x0F, 0x97),        .M,  .RM8,        .{_386} ),
    instr(.SETAE,   ops1(.rm8),                 Op2(0x0F, 0x93),        .M,  .RM8,        .{_386} ),
    instr(.SETB,    ops1(.rm8),                 Op2(0x0F, 0x92),        .M,  .RM8,        .{_386} ),
    instr(.SETBE,   ops1(.rm8),                 Op2(0x0F, 0x96),        .M,  .RM8,        .{_386} ),
    instr(.SETC,    ops1(.rm8),                 Op2(0x0F, 0x92),        .M,  .RM8,        .{_386} ),
    instr(.SETE,    ops1(.rm8),                 Op2(0x0F, 0x94),        .M,  .RM8,        .{_386} ),
    instr(.SETG,    ops1(.rm8),                 Op2(0x0F, 0x9F),        .M,  .RM8,        .{_386} ),
    instr(.SETGE,   ops1(.rm8),                 Op2(0x0F, 0x9D),        .M,  .RM8,        .{_386} ),
    instr(.SETL,    ops1(.rm8),                 Op2(0x0F, 0x9C),        .M,  .RM8,        .{_386} ),
    instr(.SETLE,   ops1(.rm8),                 Op2(0x0F, 0x9E),        .M,  .RM8,        .{_386} ),
    instr(.SETNA,   ops1(.rm8),                 Op2(0x0F, 0x96),        .M,  .RM8,        .{_386} ),
    instr(.SETNAE,  ops1(.rm8),                 Op2(0x0F, 0x92),        .M,  .RM8,        .{_386} ),
    instr(.SETNB,   ops1(.rm8),                 Op2(0x0F, 0x93),        .M,  .RM8,        .{_386} ),
    instr(.SETNBE,  ops1(.rm8),                 Op2(0x0F, 0x97),        .M,  .RM8,        .{_386} ),
    instr(.SETNC,   ops1(.rm8),                 Op2(0x0F, 0x93),        .M,  .RM8,        .{_386} ),
    instr(.SETNE,   ops1(.rm8),                 Op2(0x0F, 0x95),        .M,  .RM8,        .{_386} ),
    instr(.SETNG,   ops1(.rm8),                 Op2(0x0F, 0x9E),        .M,  .RM8,        .{_386} ),
    instr(.SETNGE,  ops1(.rm8),                 Op2(0x0F, 0x9C),        .M,  .RM8,        .{_386} ),
    instr(.SETNL,   ops1(.rm8),                 Op2(0x0F, 0x9D),        .M,  .RM8,        .{_386} ),
    instr(.SETNLE,  ops1(.rm8),                 Op2(0x0F, 0x9F),        .M,  .RM8,        .{_386} ),
    instr(.SETNO,   ops1(.rm8),                 Op2(0x0F, 0x91),        .M,  .RM8,        .{_386} ),
    instr(.SETNP,   ops1(.rm8),                 Op2(0x0F, 0x9B),        .M,  .RM8,        .{_386} ),
    instr(.SETNS,   ops1(.rm8),                 Op2(0x0F, 0x99),        .M,  .RM8,        .{_386} ),
    instr(.SETNZ,   ops1(.rm8),                 Op2(0x0F, 0x95),        .M,  .RM8,        .{_386} ),
    instr(.SETO,    ops1(.rm8),                 Op2(0x0F, 0x90),        .M,  .RM8,        .{_386} ),
    instr(.SETP,    ops1(.rm8),                 Op2(0x0F, 0x9A),        .M,  .RM8,        .{_386} ),
    instr(.SETPE,   ops1(.rm8),                 Op2(0x0F, 0x9A),        .M,  .RM8,        .{_386} ),
    instr(.SETPO,   ops1(.rm8),                 Op2(0x0F, 0x9B),        .M,  .RM8,        .{_386} ),
    instr(.SETS,    ops1(.rm8),                 Op2(0x0F, 0x98),        .M,  .RM8,        .{_386} ),
    instr(.SETZ,    ops1(.rm8),                 Op2(0x0F, 0x94),        .M,  .RM8,        .{_386} ),
// SHLD
    instr(.SHLD,    ops3(.rm16,.reg16,.imm8),   Op2(0x0F, 0xA4),        .MRI, .RM32_I8,   .{_386} ),
    instr(.SHLD,    ops3(.rm32,.reg32,.imm8),   Op2(0x0F, 0xA4),        .MRI, .RM32_I8,   .{_386} ),
    instr(.SHLD,    ops3(.rm64,.reg64,.imm8),   Op2(0x0F, 0xA4),        .MRI, .RM32_I8,   .{x86_64} ),
    //
    instr(.SHLD,    ops3(.rm16,.reg16,.reg_cl), Op2(0x0F, 0xA5),        .MR, .RM32,       .{_386} ),
    instr(.SHLD,    ops3(.rm32,.reg32,.reg_cl), Op2(0x0F, 0xA5),        .MR, .RM32,       .{_386} ),
    instr(.SHLD,    ops3(.rm64,.reg64,.reg_cl), Op2(0x0F, 0xA5),        .MR, .RM32,       .{x86_64} ),
// SHLD
    instr(.SHRD,    ops3(.rm16,.reg16,.imm8),   Op2(0x0F, 0xAC),        .MRI, .RM32_I8,   .{_386} ),
    instr(.SHRD,    ops3(.rm32,.reg32,.imm8),   Op2(0x0F, 0xAC),        .MRI, .RM32_I8,   .{_386} ),
    instr(.SHRD,    ops3(.rm64,.reg64,.imm8),   Op2(0x0F, 0xAC),        .MRI, .RM32_I8,   .{x86_64} ),
    //
    instr(.SHRD,    ops3(.rm16,.reg16,.reg_cl), Op2(0x0F, 0xAD),        .MR, .RM32,       .{_386} ),
    instr(.SHRD,    ops3(.rm32,.reg32,.reg_cl), Op2(0x0F, 0xAD),        .MR, .RM32,       .{_386} ),
    instr(.SHRD,    ops3(.rm64,.reg64,.reg_cl), Op2(0x0F, 0xAD),        .MR, .RM32,       .{x86_64} ),

//
// 80486
    instr(.BSWAP,   ops1(.reg16),               Op2(0x0F, 0xC8),        .O,  .RM32,       .{_486, edge.Undefined} ),
    instr(.BSWAP,   ops1(.reg32),               Op2(0x0F, 0xC8),        .O,  .RM32,       .{_486} ),
    instr(.BSWAP,   ops1(.reg64),               Op2(0x0F, 0xC8),        .O,  .RM32,       .{x86_64} ),
// CMPXCHG
    instr(.CMPXCHG, ops2(.rm8,  .reg8 ),        Op2(0x0F, 0xB0),        .MR, .RM8,        .{_486} ),
    instr(.CMPXCHG, ops2(.rm16, .reg16),        Op2(0x0F, 0xB1),        .MR, .RM32,       .{_486} ),
    instr(.CMPXCHG, ops2(.rm32, .reg32),        Op2(0x0F, 0xB1),        .MR, .RM32,       .{_486} ),
    instr(.CMPXCHG, ops2(.rm64, .reg64),        Op2(0x0F, 0xB1),        .MR, .RM32,       .{x86_64} ),
// INVD
    instr(.INVD,    ops0(),                     Op2(0x0F, 0x08),        .ZO, .ZO,         .{_486} ),
// INVLPG
    instr(.INVLPG,  ops1(.rm_mem),              Op2r(0x0F, 0x01, 7),    .M, .ZO,          .{_486} ),
// WBINVD
    instr(.WBINVD,  ops0(),                     Op2(0x0F, 0x09),        .ZO, .ZO,         .{_486} ),
// XADD
    instr(.XADD,    ops2(.rm8,  .reg8 ),        Op2(0x0F, 0xC0),        .MR, .RM8,        .{_486} ),
    instr(.XADD,    ops2(.rm16, .reg16),        Op2(0x0F, 0xC1),        .MR, .RM32,       .{_486} ),
    instr(.XADD,    ops2(.rm32, .reg32),        Op2(0x0F, 0xC1),        .MR, .RM32,       .{_486} ),
    instr(.XADD,    ops2(.rm64, .reg64),        Op2(0x0F, 0xC1),        .MR, .RM32,       .{x86_64} ),

//
// Pentium
//
    instr(.CPUID,      ops0(),                  Op2(0x0F, 0xA2),        .ZO, .ZO,         .{Pent} ),
// CMPXCHG8B / CMPXCHG16B
    instr(.CMPXCHG8B,  ops1(.rm_mem64),         Op2r(0x0F, 0xC7, 1),    .M, .ZO,          .{Pent} ),
    instr(.CMPXCHG16B, ops1(.rm_mem128),        Op2r(0x0F, 0xC7, 1),    .M, .REX_W,       .{Pent} ),
// RDMSR
    instr(.RDMSR,      ops0(),                  Op2(0x0F, 0x32),        .ZO, .ZO,         .{Pent} ),
// RDTSC
    instr(.RDTSC,      ops0(),                  Op2(0x0F, 0x31),        .ZO, .ZO,         .{Pent} ),
// WRMSR
    instr(.WRMSR,      ops0(),                  Op2(0x0F, 0x30),        .ZO, .ZO,         .{Pent} ),
// RSM
    instr(.RSM,        ops0(),                  Op2(0x0F, 0xAA),        .ZO, .ZO,         .{Pent} ),

//
// Pentium MMX
//
// RDPMC
    instr(.RDPMC,      ops0(),                  Op2(0x0F, 0x33),        .ZO, .ZO,         .{cpu.MMX} ),
// EMMS
    instr(.EMMS,       ops0(),               preOp2(._NP, 0x0F, 0x77),  .ZO, .ZO,         .{cpu.MMX} ),

//
// K6
//
    instr(.SYSCALL, ops0(),                   Op2(0x0F, 0x05),        .ZO, .ZO,         .{cpu.K6} ),
    instr(.SYSRET,  ops0(),                   Op2(0x0F, 0x07),        .ZO, .ZO,         .{cpu.K6} ),
    instr(.SYSRETQ, ops0(),                   Op2(0x0F, 0x07),        .ZO64, .RM32,     .{cpu.K6} ),

//
// Pentium Pro
//
// CMOVcc
    instr(.CMOVA,   ops2(.reg16, .rm16),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVA,   ops2(.reg32, .rm32),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVA,   ops2(.reg64, .rm64),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVAE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVAE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVAE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVB,   ops2(.reg16, .rm16),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVB,   ops2(.reg32, .rm32),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVB,   ops2(.reg64, .rm64),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVBE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVBE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVBE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVC,   ops2(.reg16, .rm16),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVC,   ops2(.reg32, .rm32),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVC,   ops2(.reg64, .rm64),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVE,   ops2(.reg16, .rm16),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVE,   ops2(.reg32, .rm32),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVE,   ops2(.reg64, .rm64),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVG,   ops2(.reg16, .rm16),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVG,   ops2(.reg32, .rm32),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVG,   ops2(.reg64, .rm64),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVGE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVGE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVGE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVL,   ops2(.reg16, .rm16),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVL,   ops2(.reg32, .rm32),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVL,   ops2(.reg64, .rm64),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVLE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVLE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVLE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNA,  ops2(.reg16, .rm16),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNA,  ops2(.reg32, .rm32),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNA,  ops2(.reg64, .rm64),      Op2(0x0F, 0x46),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNAE, ops2(.reg16, .rm16),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNAE, ops2(.reg32, .rm32),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNAE, ops2(.reg64, .rm64),      Op2(0x0F, 0x42),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNB,  ops2(.reg16, .rm16),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNB,  ops2(.reg32, .rm32),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNB,  ops2(.reg64, .rm64),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNBE, ops2(.reg16, .rm16),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNBE, ops2(.reg32, .rm32),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNBE, ops2(.reg64, .rm64),      Op2(0x0F, 0x47),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNC,  ops2(.reg16, .rm16),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNC,  ops2(.reg32, .rm32),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNC,  ops2(.reg64, .rm64),      Op2(0x0F, 0x43),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNG,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNG,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNG,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4E),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNGE, ops2(.reg16, .rm16),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNGE, ops2(.reg32, .rm32),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNGE, ops2(.reg64, .rm64),      Op2(0x0F, 0x4C),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNL,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNL,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNL,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4D),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNLE, ops2(.reg16, .rm16),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNLE, ops2(.reg32, .rm32),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNLE, ops2(.reg64, .rm64),      Op2(0x0F, 0x4F),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNO,  ops2(.reg16, .rm16),      Op2(0x0F, 0x41),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNO,  ops2(.reg32, .rm32),      Op2(0x0F, 0x41),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNO,  ops2(.reg64, .rm64),      Op2(0x0F, 0x41),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNP,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNP,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNP,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNS,  ops2(.reg16, .rm16),      Op2(0x0F, 0x49),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNS,  ops2(.reg32, .rm32),      Op2(0x0F, 0x49),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNS,  ops2(.reg64, .rm64),      Op2(0x0F, 0x49),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVNZ,  ops2(.reg16, .rm16),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNZ,  ops2(.reg32, .rm32),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVNZ,  ops2(.reg64, .rm64),      Op2(0x0F, 0x45),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVO,   ops2(.reg16, .rm16),      Op2(0x0F, 0x40),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVO,   ops2(.reg32, .rm32),      Op2(0x0F, 0x40),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVO,   ops2(.reg64, .rm64),      Op2(0x0F, 0x40),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVP,   ops2(.reg16, .rm16),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVP,   ops2(.reg32, .rm32),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVP,   ops2(.reg64, .rm64),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVPE,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVPE,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVPE,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4A),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVPO,  ops2(.reg16, .rm16),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVPO,  ops2(.reg32, .rm32),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVPO,  ops2(.reg64, .rm64),      Op2(0x0F, 0x4B),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVS,   ops2(.reg16, .rm16),      Op2(0x0F, 0x48),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVS,   ops2(.reg32, .rm32),      Op2(0x0F, 0x48),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVS,   ops2(.reg64, .rm64),      Op2(0x0F, 0x48),        .RM, .RM32,       .{cpu.P6, x86_64} ),
    //
    instr(.CMOVZ,   ops2(.reg16, .rm16),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVZ,   ops2(.reg32, .rm32),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6} ),
    instr(.CMOVZ,   ops2(.reg64, .rm64),      Op2(0x0F, 0x44),        .RM, .RM32,       .{cpu.P6, x86_64} ),
// UD
    instr(.UD0, ops2(.reg16, .rm16),          Op2(0x0F, 0xFF),        .RM, .RM32,       .{cpu.PentPro} ),
    instr(.UD0, ops2(.reg32, .rm32),          Op2(0x0F, 0xFF),        .RM, .RM32,       .{cpu.PentPro} ),
    instr(.UD0, ops2(.reg64, .rm64),          Op2(0x0F, 0xFF),        .RM, .RM32,       .{cpu.PentPro} ),
    //
    instr(.UD1, ops2(.reg16, .rm16),          Op2(0x0F, 0xB9),        .RM, .RM32,       .{cpu.PentPro} ),
    instr(.UD1, ops2(.reg32, .rm32),          Op2(0x0F, 0xB9),        .RM, .RM32,       .{cpu.PentPro} ),
    instr(.UD1, ops2(.reg64, .rm64),          Op2(0x0F, 0xB9),        .RM, .RM32,       .{cpu.PentPro} ),
    //
    instr(.UD2, ops0(),                       Op2(0x0F, 0x0B),        .ZO, .ZO,         .{cpu.PentPro} ),

//
// Pentium II
//
    instr(.SYSENTER, ops0(),                  Op2(0x0F, 0x34),        .ZO, .ZO,         .{cpu.Pent2} ),
    instr(.SYSEXIT,  ops0(),                  Op2(0x0F, 0x35),        .ZO, .ZO,         .{cpu.Pent2} ),
    instr(.SYSEXITQ, ops0(),                  Op2(0x0F, 0x35),        .ZO64, .RM32,     .{cpu.Pent2} ),

//
// x86-64
//
    instr(.RDTSCP, ops0(),                    Op3(0x0F, 0x01, 0xF9),  .ZO, .ZO,         .{x86_64} ),
    instr(.SWAPGS, ops0(),                    Op3(0x0F, 0x01, 0xF8),  .ZO, .ZO,         .{x86_64} ),

//
// bit manipulation (ABM / BMI1 / BMI2)
//
// LZCNT
    instr(.LZCNT,   ops2(.reg16, .rm16),            preOp2(._F3, 0x0F, 0xBD),         .RM, .RM32,  .{ABM} ),
    instr(.LZCNT,   ops2(.reg32, .rm32),            preOp2(._F3, 0x0F, 0xBD),         .RM, .RM32,  .{ABM} ),
    instr(.LZCNT,   ops2(.reg64, .rm64),            preOp2(._F3, 0x0F, 0xBD),         .RM, .RM32,  .{ABM, x86_64} ),
// LZCNT
    instr(.POPCNT,  ops2(.reg16, .rm16),            preOp2(._F3, 0x0F, 0xB8),         .RM, .RM32,  .{ABM} ),
    instr(.POPCNT,  ops2(.reg32, .rm32),            preOp2(._F3, 0x0F, 0xB8),         .RM, .RM32,  .{ABM} ),
    instr(.POPCNT,  ops2(.reg64, .rm64),            preOp2(._F3, 0x0F, 0xB8),         .RM, .RM32,  .{ABM, x86_64} ),
// ANDN
    instr(.ANDN,    ops3(.reg32, .reg32, .rm32),    vex(.LZ,._NP,._0F38,.W0, 0xF2),   .RVM, .ZO,   .{BMI1} ),
    instr(.ANDN,    ops3(.reg64, .reg64, .rm64),    vex(.LZ,._NP,._0F38,.W1, 0xF2),   .RVM, .ZO,   .{BMI1} ),
// BEXTR
    instr(.BEXTR,   ops3(.reg32, .rm32, .reg32),    vex(.LZ,._NP,._0F38,.W0, 0xF7),   .RMV, .ZO,   .{BMI1} ),
    instr(.BEXTR,   ops3(.reg64, .rm64, .reg64),    vex(.LZ,._NP,._0F38,.W1, 0xF7),   .RMV, .ZO,   .{BMI1} ),
// BLSI
    instr(.BLSI,    ops2(.reg32, .rm32),            vexr(.LZ,._NP,._0F38,.W0,0xF3, 3),.VM, .ZO,    .{BMI1} ),
    instr(.BLSI,    ops2(.reg64, .rm64),            vexr(.LZ,._NP,._0F38,.W1,0xF3, 3),.VM, .ZO,    .{BMI1} ),
// BLSMSK
    instr(.BLSMSK,  ops2(.reg32, .rm32),            vexr(.LZ,._NP,._0F38,.W0,0xF3, 2),.VM, .ZO,    .{BMI1} ),
    instr(.BLSMSK,  ops2(.reg64, .rm64),            vexr(.LZ,._NP,._0F38,.W1,0xF3, 2),.VM, .ZO,    .{BMI1} ),
// BLSR
    instr(.BLSR,    ops2(.reg32, .rm32),            vexr(.LZ,._NP,._0F38,.W0,0xF3, 1),.VM, .ZO,    .{BMI1} ),
    instr(.BLSR,    ops2(.reg64, .rm64),            vexr(.LZ,._NP,._0F38,.W1,0xF3, 1),.VM, .ZO,    .{BMI1} ),
// BZHI
    instr(.BZHI,    ops3(.reg32, .rm32, .reg32),    vex(.LZ,._NP,._0F38,.W0, 0xF5),   .RMV, .ZO,   .{BMI2} ),
    instr(.BZHI,    ops3(.reg64, .rm64, .reg64),    vex(.LZ,._NP,._0F38,.W1, 0xF5),   .RMV, .ZO,   .{BMI2} ),
// MULX
    instr(.MULX,    ops3(.reg32, .reg32, .rm32),    vex(.LZ,._F2,._0F38,.W0, 0xF6),   .RVM, .ZO,   .{BMI2} ),
    instr(.MULX,    ops3(.reg64, .reg64, .rm64),    vex(.LZ,._F2,._0F38,.W1, 0xF6),   .RVM, .ZO,   .{BMI2} ),
// PDEP
    instr(.PDEP,    ops3(.reg32, .reg32, .rm32),    vex(.LZ,._F2,._0F38,.W0, 0xF5),   .RVM, .ZO,   .{BMI2} ),
    instr(.PDEP,    ops3(.reg64, .reg64, .rm64),    vex(.LZ,._F2,._0F38,.W1, 0xF5),   .RVM, .ZO,   .{BMI2} ),
// PEXT
    instr(.PEXT,    ops3(.reg32, .reg32, .rm32),    vex(.LZ,._F3,._0F38,.W0, 0xF5),   .RVM, .ZO,   .{BMI2} ),
    instr(.PEXT,    ops3(.reg64, .reg64, .rm64),    vex(.LZ,._F3,._0F38,.W1, 0xF5),   .RVM, .ZO,   .{BMI2} ),
// RORX
    instr(.RORX,    ops3(.reg32, .rm32, .imm8),     vex(.LZ,._F2,._0F3A,.W0, 0xF0),   .vRMI,.ZO,   .{BMI2} ),
    instr(.RORX,    ops3(.reg64, .rm64, .imm8),     vex(.LZ,._F2,._0F3A,.W1, 0xF0),   .vRMI,.ZO,   .{BMI2} ),
// SARX
    instr(.SARX,    ops3(.reg32, .rm32, .reg32),    vex(.LZ,._F3,._0F38,.W0, 0xF7),   .RMV, .ZO,   .{BMI2} ),
    instr(.SARX,    ops3(.reg64, .rm64, .reg64),    vex(.LZ,._F3,._0F38,.W1, 0xF7),   .RMV, .ZO,   .{BMI2} ),
// SHLX
    instr(.SHLX,    ops3(.reg32, .rm32, .reg32),    vex(.LZ,._66,._0F38,.W0, 0xF7),   .RMV, .ZO,   .{BMI2} ),
    instr(.SHLX,    ops3(.reg64, .rm64, .reg64),    vex(.LZ,._66,._0F38,.W1, 0xF7),   .RMV, .ZO,   .{BMI2} ),
// SHRX
    instr(.SHRX,    ops3(.reg32, .rm32, .reg32),    vex(.LZ,._F2,._0F38,.W0, 0xF7),   .RMV, .ZO,   .{BMI2} ),
    instr(.SHRX,    ops3(.reg64, .rm64, .reg64),    vex(.LZ,._F2,._0F38,.W1, 0xF7),   .RMV, .ZO,   .{BMI2} ),
// TZCNT
    instr(.TZCNT,   ops2(.reg16, .rm16),            preOp2(._F3, 0x0F, 0xBC),         .RM, .RM32,  .{BMI1} ),
    instr(.TZCNT,   ops2(.reg32, .rm32),            preOp2(._F3, 0x0F, 0xBC),         .RM, .RM32,  .{BMI1} ),
    instr(.TZCNT,   ops2(.reg64, .rm64),            preOp2(._F3, 0x0F, 0xBC),         .RM, .RM32,  .{BMI1, x86_64} ),
//
// TBM (AMD specific/legacy)
//
// TODO

//
// Misc Extensions
//
// ADX
    // ADCX
    instr(.ADCX,       ops2(.reg32, .rm32),          preOp3(._66, 0x0F, 0x38, 0xF6),      .RM, .RM32,  .{ADX} ),
    instr(.ADCX,       ops2(.reg64, .rm64),          preOp3(._66, 0x0F, 0x38, 0xF6),      .RM, .RM32,  .{ADX} ),
    // ADOX
    instr(.ADOX,       ops2(.reg32, .rm32),          preOp3(._F3, 0x0F, 0x38, 0xF6),      .RM, .RM32,  .{ADX} ),
    instr(.ADOX,       ops2(.reg64, .rm64),          preOp3(._F3, 0x0F, 0x38, 0xF6),      .RM, .RM32,  .{ADX} ),
// CLDEMOTE
    instr(.CLDEMOTE,   ops1(.rm_mem8),               preOp2r(._NP, 0x0F, 0x1C, 0),        .M, .RM8,    .{CLDEMOTE} ),
// CLFLUSHOPT
    instr(.CLFLUSHOPT, ops1(.rm_mem8),               preOp2r(._66, 0x0F, 0xAE, 7),        .M, .RM8,    .{CLFLUSHOPT} ),
// CET_IBT
    instr(.ENDBR32,    ops0(),                       preOp3(._F3, 0x0F, 0x1E, 0xFB),      .ZO, .ZO,    .{CET_IBT} ),
    instr(.ENDBR64,    ops0(),                       preOp3(._F3, 0x0F, 0x1E, 0xFA),      .ZO, .ZO,    .{CET_IBT} ),
// CET_SS
    // CLRSSBSY
    instr(.CLRSSBSY,   ops1(.rm_mem64),              preOp2r(._F3, 0x0F, 0xAE, 6),        .M, .ZO,     .{CET_SS} ),
    // INCSSPD / INCSSPQ
    instr(.INCSSPD,    ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xAE, 5),        .M, .RM32,   .{CET_SS} ),
    instr(.INCSSPQ,    ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xAE, 5),        .M, .RM32,   .{CET_SS} ),
    // RDSSP
    instr(.RDSSPD,     ops1(.reg32),                 preOp2r(._F3, 0x0F, 0x1E, 1),        .M, .RM32,   .{CET_SS} ),
    instr(.RDSSPQ,     ops1(.reg64),                 preOp2r(._F3, 0x0F, 0x1E, 1),        .M, .RM32,   .{CET_SS} ),
    // RSTORSSP
    instr(.RSTORSSP,   ops1(.rm_mem64),              preOp2r(._F3, 0x0F, 0x01, 5),        .M, .ZO,     .{CET_SS} ),
    // SAVEPREVSSP
    instr(.SAVEPREVSSP,ops0(),                       preOp3(._F3, 0x0F, 0x01, 0xEA),      .ZO,.ZO,     .{CET_SS} ),
    // SETSSBSY
    instr(.SETSSBSY,   ops0(),                       preOp3(._F3, 0x0F, 0x01, 0xE8),      .ZO,.ZO,     .{CET_SS} ),
    // WRSS
    instr(.WRSSD,      ops2(.rm32, .reg32),             Op3(0x0F, 0x38, 0xF6),            .MR, .RM32,  .{CET_SS} ),
    instr(.WRSSQ,      ops2(.rm64, .reg64),             Op3(0x0F, 0x38, 0xF6),            .MR, .RM32,  .{CET_SS} ),
    // WRUSS
    instr(.WRUSSD,     ops2(.rm32, .reg32),          preOp3(._66, 0x0F, 0x38, 0xF5),      .MR, .RM32,  .{CET_SS} ),
    instr(.WRUSSQ,     ops2(.rm64, .reg64),          preOp3(._66, 0x0F, 0x38, 0xF5),      .MR, .RM32,  .{CET_SS} ),
// CLWB
    instr(.CLWB,       ops1(.rm_mem8),               preOp2r(._66, 0x0F, 0xAE, 6),        .M, .RM8,    .{CLWB} ),
// FSGSBASE
    // RDFSBASE
    instr(.RDFSBASE,   ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xAE, 0),        .M, .RM32,   .{FSGSBASE} ),
    instr(.RDFSBASE,   ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xAE, 0),        .M, .RM32,   .{FSGSBASE} ),
    // RDGSBASE
    instr(.RDGSBASE,   ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xAE, 1),        .M, .RM32,   .{FSGSBASE} ),
    instr(.RDGSBASE,   ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xAE, 1),        .M, .RM32,   .{FSGSBASE} ),
    // WRFSBASE
    instr(.WRFSBASE,   ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xAE, 2),        .M, .RM32,   .{FSGSBASE} ),
    instr(.WRFSBASE,   ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xAE, 2),        .M, .RM32,   .{FSGSBASE} ),
    // WRGSBASE
    instr(.WRGSBASE,   ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xAE, 3),        .M, .RM32,   .{FSGSBASE} ),
    instr(.WRGSBASE,   ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xAE, 3),        .M, .RM32,   .{FSGSBASE} ),
// FXRSTOR
    instr(.FXRSTOR,    ops1(.rm_mem),                preOp2r(._NP, 0x0F, 0xAE, 1),        .M, .ZO,     .{FXSR} ),
    instr(.FXRSTOR64,  ops1(.rm_mem),                preOp2r(._NP, 0x0F, 0xAE, 1),        .M, .REX_W,  .{FXSR, No32} ),
// FXSAVE
    instr(.FXSAVE,     ops1(.rm_mem),                preOp2r(._NP, 0x0F, 0xAE, 0),        .M, .ZO,     .{FXSR} ),
    instr(.FXSAVE64,   ops1(.rm_mem),                preOp2r(._NP, 0x0F, 0xAE, 0),        .M, .REX_W,  .{FXSR, No32} ),
// SGX
    instr(.ENCLS,      ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xCF),      .ZO,.ZO,     .{SGX} ),
    instr(.ENCLU,      ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xD7),      .ZO,.ZO,     .{SGX} ),
    instr(.ENCLV,      ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xC0),      .ZO,.ZO,     .{SGX} ),
// SMX
    instr(.GETSEC,     ops0(),                       preOp2(._NP, 0x0F, 0x37),            .ZO,.ZO,     .{SMX} ),
// GFNI
    instr(.GF2P8AFFINEINVQB, ops3(.xmml, .xmml_m128, .imm8), preOp3(._66, 0x0F, 0x3A, 0xCF), .RMI,.ZO, .{GFNI} ),
    instr(.GF2P8AFFINEQB,    ops3(.xmml, .xmml_m128, .imm8), preOp3(._66, 0x0F, 0x3A, 0xCE), .RMI,.ZO, .{GFNI} ),
    instr(.GF2P8MULB,        ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xCF), .RM, .ZO, .{GFNI} ),
// INVPCID
    instr(.INVPCID,    ops2(.reg32, .rm_mem128),     preOp3(._66, 0x0F, 0x38, 0x82),      .RM, .ZO,    .{INVPCID, No64} ),
    instr(.INVPCID,    ops2(.reg64, .rm_mem128),     preOp3(._66, 0x0F, 0x38, 0x82),      .RM, .ZO,    .{INVPCID, No32} ),
// MOVBE
    instr(.MOVBE,      ops2(.reg16, .rm_mem16),         Op3(0x0F, 0x38, 0xF0),            .RM, .RM32,  .{MOVBE} ),
    instr(.MOVBE,      ops2(.reg32, .rm_mem32),         Op3(0x0F, 0x38, 0xF0),            .RM, .RM32,  .{MOVBE} ),
    instr(.MOVBE,      ops2(.reg64, .rm_mem64),         Op3(0x0F, 0x38, 0xF0),            .RM, .RM32,  .{MOVBE} ),
    //
    instr(.MOVBE,      ops2(.rm_mem16, .reg16),         Op3(0x0F, 0x38, 0xF1),            .MR, .RM32,  .{MOVBE} ),
    instr(.MOVBE,      ops2(.rm_mem32, .reg32),         Op3(0x0F, 0x38, 0xF1),            .MR, .RM32,  .{MOVBE} ),
    instr(.MOVBE,      ops2(.rm_mem64, .reg64),         Op3(0x0F, 0x38, 0xF1),            .MR, .RM32,  .{MOVBE} ),
// MOVDIRI
    instr(.MOVDIRI,    ops2(.rm_mem32, .reg32),      preOp3(._NP, 0x0F, 0x38, 0xF9),      .MR, .RM32,  .{MOVDIRI} ),
    instr(.MOVDIRI,    ops2(.rm_mem64, .reg64),      preOp3(._NP, 0x0F, 0x38, 0xF9),      .MR, .RM32,  .{MOVDIRI} ),
// MOVDIR64B
    instr(.MOVDIR64B,  ops2(.reg16, .rm_mem),        preOp3(._66, 0x0F, 0x38, 0xF8),      .RM, .R_Over16, .{MOVDIR64B, No64} ),
    instr(.MOVDIR64B,  ops2(.reg32, .rm_mem),        preOp3(._66, 0x0F, 0x38, 0xF8),      .RM, .R_Over32, .{MOVDIR64B} ),
    instr(.MOVDIR64B,  ops2(.reg64, .rm_mem),        preOp3(._66, 0x0F, 0x38, 0xF8),      .RM, .R_Over64, .{MOVDIR64B, No32} ),
// MPX
    instr(.BNDCL,      ops2(.bnd, .rm32),            preOp2(._F3, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No64} ),
    instr(.BNDCL,      ops2(.bnd, .rm64),            preOp2(._F3, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No32} ),
    //
    instr(.BNDCU,      ops2(.bnd, .rm32),            preOp2(._F2, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No64} ),
    instr(.BNDCU,      ops2(.bnd, .rm64),            preOp2(._F2, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No32} ),
    instr(.BNDCN,      ops2(.bnd, .rm32),            preOp2(._F2, 0x0F, 0x1B),            .RM, .ZO,    .{MPX, No64} ),
    instr(.BNDCN,      ops2(.bnd, .rm64),            preOp2(._F2, 0x0F, 0x1B),            .RM, .ZO,    .{MPX, No32} ),
    // TODO/NOTE: special `mib` encoding actually requires SIB and is not used as normal memory
    instr(.BNDLDX,     ops2(.bnd, .rm_mem),          preOp2(._NP, 0x0F, 0x1A),            .RM, .ZO,    .{MPX} ),
    //
    instr(.BNDMK,      ops2(.bnd, .rm_mem32),        preOp2(._F3, 0x0F, 0x1B),            .RM, .ZO,    .{MPX, No64} ),
    instr(.BNDMK,      ops2(.bnd, .rm_mem64),        preOp2(._F3, 0x0F, 0x1B),            .RM, .ZO,    .{MPX, No32} ),
    //
    instr(.BNDMOV,     ops2(.bnd, .bnd_m64),         preOp2(._66, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No64} ),
    instr(.BNDMOV,     ops2(.bnd, .bnd_m128),        preOp2(._66, 0x0F, 0x1A),            .RM, .ZO,    .{MPX, No32} ),
    instr(.BNDMOV,     ops2(.bnd_m64, .bnd),         preOp2(._66, 0x0F, 0x1B),            .MR, .ZO,    .{MPX, No64} ),
    instr(.BNDMOV,     ops2(.bnd_m128, .bnd),        preOp2(._66, 0x0F, 0x1B),            .MR, .ZO,    .{MPX, No32} ),
    // TODO/NOTE: special `mib` encoding actually requires SIB and is not used as normal memory
    instr(.BNDSTX,     ops2(.rm_mem, .bnd),          preOp2(._NP, 0x0F, 0x1B),            .MR, .ZO,    .{MPX} ),
// PKRU
    instr(.RDPKRU,     ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xEE),      .ZO, .ZO,    .{PKRU, OSPKE} ),
    instr(.WRPKRU,     ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xEF),      .ZO, .ZO,    .{PKRU, OSPKE} ),
// PREFETCHW
    instr(.PREFETCHW,  ops1(.rm_mem8),                  Op2r(0x0F, 0x0D, 1),              .M, .ZO,     .{PREFETCHW} ),
// PTWRITE
    instr(.PTWRITE,    ops1(.rm32),                  preOp2r(._F3, 0x0F, 0xAE, 4),        .M, .RM32,   .{PTWRITE} ),
    instr(.PTWRITE,    ops1(.rm64),                  preOp2r(._F3, 0x0F, 0xAE, 4),        .M, .RM32,   .{PTWRITE} ),
// RDPID
    instr(.RDPID,      ops1(.reg32),                 preOp2r(._F3, 0x0F, 0xC7, 7),        .M, .ZO,     .{RDPID, No64} ),
    instr(.RDPID,      ops1(.reg64),                 preOp2r(._F3, 0x0F, 0xC7, 7),        .M, .ZO,     .{RDPID, No32} ),
// RDRAND
    instr(.RDRAND,     ops1(.reg16),                 preOp2r(.NFx, 0x0F, 0xC7, 6),        .M, .RM32,   .{RDRAND} ),
    instr(.RDRAND,     ops1(.reg32),                 preOp2r(.NFx, 0x0F, 0xC7, 6),        .M, .RM32,   .{RDRAND} ),
    instr(.RDRAND,     ops1(.reg64),                 preOp2r(.NFx, 0x0F, 0xC7, 6),        .M, .RM32,   .{RDRAND} ),
// RDSEED
    instr(.RDSEED,     ops1(.reg16),                 preOp2r(.NFx, 0x0F, 0xC7, 7),        .M, .RM32,   .{RDSEED} ),
    instr(.RDSEED,     ops1(.reg32),                 preOp2r(.NFx, 0x0F, 0xC7, 7),        .M, .RM32,   .{RDSEED} ),
    instr(.RDSEED,     ops1(.reg64),                 preOp2r(.NFx, 0x0F, 0xC7, 7),        .M, .RM32,   .{RDSEED} ),
// SMAP
    instr(.CLAC,       ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xCA),      .ZO, .ZO,    .{SMAP} ),
    instr(.STAC,       ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xCB),      .ZO, .ZO,    .{SMAP} ),
// TDX (HLE / RTM)
    // HLE (NOTE: these instructions actually act as prefixes)
    instr(.XACQUIRE,   ops0(),                          Op1(0xF2),                        .ZO,.ZO,     .{HLE} ),
    instr(.XRELEASE,   ops0(),                          Op1(0xF3),                        .ZO,.ZO,     .{HLE} ),
    // RTM
    instr(.XABORT,     ops1(.imm8),                     Op2(0xC6, 0xF8),                  .I, .ZO,     .{RTM} ),
    instr(.XBEGIN,     ops1(.imm16),                    Op2(0xC7, 0xF8),                  .I, .RM32,   .{Sign, RTM} ),
    instr(.XBEGIN,     ops1(.imm32),                    Op2(0xC7, 0xF8),                  .I, .RM32,   .{Sign, RTM} ),
    instr(.XEND,       ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xD5),      .ZO,.ZO,     .{RTM} ),
    // TDX (HLE or RTM)
    instr(.XTEST,      ops0(),                       preOp3(._NP, 0x0F, 0x01, 0xD6),      .ZO,.ZO,     .{TDX} ),
// WAITPKG
    //
    instr(.UMONITOR,   ops1(.reg16),                  preOp2r(._F3, 0x0F, 0xAE, 6),       .M, .R_Over16, .{WAITPKG, No64} ),
    instr(.UMONITOR,   ops1(.reg32),                  preOp2r(._F3, 0x0F, 0xAE, 6),       .M, .R_Over32, .{WAITPKG} ),
    instr(.UMONITOR,   ops1(.reg64),                  preOp2r(._F3, 0x0F, 0xAE, 6),       .M, .ZO,       .{WAITPKG, No32} ),
    //
    instr(.UMWAIT,     ops3(.reg32,.reg_edx,.reg_eax),preOp2r(._F2, 0x0F, 0xAE, 6),       .M, .ZO,     .{WAITPKG} ),
    instr(.UMWAIT,     ops1(.reg32),                  preOp2r(._F2, 0x0F, 0xAE, 6),       .M, .ZO,     .{WAITPKG} ),
    //
    instr(.TPAUSE,     ops3(.reg32,.reg_edx,.reg_eax),preOp2r(._66, 0x0F, 0xAE, 6),       .M, .ZO,     .{WAITPKG} ),
    instr(.TPAUSE,     ops1(.reg32),                  preOp2r(._66, 0x0F, 0xAE, 6),       .M, .ZO,     .{WAITPKG} ),
// XSAVE
    // XGETBV
    instr(.XGETBV,     ops0(),                        preOp3(._NP, 0x0F, 0x01, 0xD0),     .ZO,.ZO,     .{XSAVE} ),
    // XSETBV
    instr(.XSETBV,     ops0(),                        preOp3(._NP, 0x0F, 0x01, 0xD1),     .ZO,.ZO,     .{XSAVE} ),
    // FXSAE
    instr(.XSAVE,      ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 4),       .M, .ZO,     .{XSAVE} ),
    instr(.XSAVE64,    ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 4),       .M, .REX_W,  .{XSAVE, No32} ),
    // FXRSTO
    instr(.XRSTOR,     ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 5),       .M, .ZO,     .{XSAVE} ),
    instr(.XRSTOR64,   ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 5),       .M, .REX_W,  .{XSAVE, No32} ),
// XSAVEOPT
    instr(.XSAVEOPT,   ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 6),       .M, .ZO,     .{XSAVEOPT} ),
    instr(.XSAVEOPT64, ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xAE, 6),       .M, .REX_W,  .{XSAVEOPT, No32} ),
// XSAVEC
    instr(.XSAVEC,     ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 4),       .M, .ZO,     .{XSAVEC} ),
    instr(.XSAVEC64,   ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 4),       .M, .REX_W,  .{XSAVEC, No32} ),
// XSS
    instr(.XSAVES,     ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 5),       .M, .ZO,     .{XSS} ),
    instr(.XSAVES64,   ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 5),       .M, .REX_W,  .{XSS, No32} ),
    //
    instr(.XRSTORS,    ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 3),       .M, .ZO,     .{XSS} ),
    instr(.XRSTORS64,  ops1(.rm_mem),                 preOp2r(._NP, 0x0F, 0xC7, 3),       .M, .REX_W,  .{XSS, No32} ),


//
// AES instructions
//
    instr(.AESDEC,          ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xDE),  .RM,  .ZO, .{AES} ),
    instr(.AESDECLAST,      ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xDF),  .RM,  .ZO, .{AES} ),
    instr(.AESENC,          ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xDC),  .RM,  .ZO, .{AES} ),
    instr(.AESENCLAST,      ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xDD),  .RM,  .ZO, .{AES} ),
    instr(.AESIMC,          ops2(.xmml, .xmml_m128),        preOp3(._66, 0x0F, 0x38, 0xDB),  .RM,  .ZO, .{AES} ),
    instr(.AESKEYGENASSIST, ops3(.xmml, .xmml_m128, .imm8), preOp3(._66, 0x0F, 0x3A, 0xDF),  .RMI, .ZO, .{AES} ),

//
// SHA instructions
//
    instr(.SHA1RNDS4,   ops3(.xmml, .xmml_m128, .imm8),     preOp3(._NP, 0x0F, 0x3A, 0xCC),  .RMI, .ZO, .{SHA} ),
    instr(.SHA1NEXTE,   ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xC8),  .RM,  .ZO, .{SHA} ),
    instr(.SHA1MSG1,    ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xC9),  .RM,  .ZO, .{SHA} ),
    instr(.SHA1MSG2,    ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xCA),  .RM,  .ZO, .{SHA} ),
    instr(.SHA256RNDS2, ops3(.xmml, .xmml_m128, .xmm0),     preOp3(._NP, 0x0F, 0x38, 0xCB),  .RM,  .ZO, .{SHA} ),
    instr(.SHA256RNDS2, ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xCB),  .RM,  .ZO, .{SHA} ),
    instr(.SHA256MSG1,  ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xCC),  .RM,  .ZO, .{SHA} ),
    instr(.SHA256MSG2,  ops2(.xmml, .xmml_m128),            preOp3(._NP, 0x0F, 0x38, 0xCD),  .RM,  .ZO, .{SHA} ),

//
// SSE non-VEX/EVEX opcodes
//
// LDMXCSR
    instr(.LDMXCSR,     ops1(.rm_mem32),         preOp2r(._NP, 0x0F, 0xAE, 2),    .M,  .ZO,        .{SSE} ),
// STMXCSR
    instr(.STMXCSR,     ops1(.rm_mem32),         preOp2r(._NP, 0x0F, 0xAE, 3),    .M,  .ZO,        .{SSE} ),
// PREFETCH
    instr(.PREFETCHNTA, ops1(.rm_mem8),             Op2r(0x0F, 0x18, 0),          .M,  .RM8,       .{SSE} ),
    instr(.PREFETCHT0,  ops1(.rm_mem8),             Op2r(0x0F, 0x18, 1),          .M,  .RM8,       .{SSE} ),
    instr(.PREFETCHT1,  ops1(.rm_mem8),             Op2r(0x0F, 0x18, 2),          .M,  .RM8,       .{SSE} ),
    instr(.PREFETCHT2,  ops1(.rm_mem8),             Op2r(0x0F, 0x18, 3),          .M,  .RM8,       .{SSE} ),
// SFENCE
    instr(.SFENCE,      ops0(),                  preOp3(._NP, 0x0F, 0xAE, 0xF8),  .ZO, .ZO,        .{SSE} ),
// CLFLUSH
    instr(.CLFLUSH,     ops1(.rm_mem8),          preOp2r(._NP, 0x0F, 0xAE, 7),    .M,  .RM8,       .{SSE2} ),
// LFENCE
    instr(.LFENCE,      ops0(),                  preOp3(._NP, 0x0F, 0xAE, 0xE8),  .ZO, .ZO,        .{SSE2} ),
// MFENCE
    instr(.MFENCE,      ops0(),                  preOp3(._NP, 0x0F, 0xAE, 0xF0),  .ZO, .ZO,        .{SSE2} ),
// MOVNTI
    instr(.MOVNTI,      ops2(.rm_mem32, .reg32), preOp2(._NP, 0x0F, 0xC3),        .MR, .RM32,      .{SSE2} ),
    instr(.MOVNTI,      ops2(.rm_mem64, .reg64), preOp2(._NP, 0x0F, 0xC3),        .MR, .RM32,      .{SSE2} ),
// PAUSE
    instr(.PAUSE,       ops0(),                  preOp1(._F3, 0x90),              .ZO, .ZO,        .{SSE2} ),
// MONITOR
    instr(.MONITOR,     ops0(),                     Op3(0x0F, 0x01, 0xC8),        .ZO, .ZO,        .{SSE3} ),
// MWAIT
    instr(.MWAIT,       ops0(),                     Op3(0x0F, 0x01, 0xC9),        .ZO, .ZO,        .{SSE3} ),
// CRC32
    instr(.CRC32,       ops2(.reg32, .rm8),      preOp3(._F2, 0x0F, 0x38, 0xF0),  .RM, .RM32_Reg,  .{SSE4_2} ),
    instr(.CRC32,       ops2(.reg64, .rm8),      preOp3(._F2, 0x0F, 0x38, 0xF0),  .RM, .RM32_Reg,  .{SSE4_2} ),
    instr(.CRC32,       ops2(.reg32, .rm16),     preOp3(._F2, 0x0F, 0x38, 0xF1),  .RM, .RM32_RM,   .{SSE4_2} ),
    instr(.CRC32,       ops2(.reg32, .rm32),     preOp3(._F2, 0x0F, 0x38, 0xF1),  .RM, .RM32_RM,   .{SSE4_2} ),
    instr(.CRC32,       ops2(.reg64, .rm64),     preOp3(._F2, 0x0F, 0x38, 0xF1),  .RM, .RM32_RM,   .{SSE4_2} ),

//
// AMD-V
// CLGI
    instr(.CLGI, ops0(),                    Op3(0x0F, 0x01, 0xDD),   .ZO, .ZO,              .{cpu.AMD_V} ),
// INVLPGA
    instr(.INVLPGA, ops0(),                 Op3(0x0F, 0x01, 0xDF),   .ZO, .ZO,              .{cpu.AMD_V} ),
    instr(.INVLPGA, ops2(.reg_ax,.reg_ecx), Op3(0x0F, 0x01, 0xDF),   .ZO16, .R_Over16,      .{No64, cpu.AMD_V} ),
    instr(.INVLPGA, ops2(.reg_eax,.reg_ecx),Op3(0x0F, 0x01, 0xDF),   .ZO32, .R_Over32,      .{cpu.AMD_V} ),
    instr(.INVLPGA, ops2(.reg_rax,.reg_ecx),Op3(0x0F, 0x01, 0xDF),   .ZO64, .RM64,          .{No32, cpu.AMD_V} ),
// SKINIT
    instr(.SKINIT,  ops0(),                 Op3(0x0F, 0x01, 0xDE),   .ZO, .ZO,              .{cpu.AMD_V} ),
    instr(.SKINIT,  ops1(.reg_eax),         Op3(0x0F, 0x01, 0xDE),   .ZO, .ZO,              .{cpu.AMD_V} ),
// STGI
    instr(.STGI,    ops0(),                 Op3(0x0F, 0x01, 0xDC),   .ZO, .ZO,              .{cpu.AMD_V} ),
// VMLOAD
    instr(.VMLOAD,  ops0(),                 Op3(0x0F, 0x01, 0xDA),   .ZO, .ZO,              .{cpu.AMD_V} ),
    instr(.VMLOAD,  ops1(.reg_ax),          Op3(0x0F, 0x01, 0xDA),   .ZO16, .R_Over16,      .{No64, cpu.AMD_V} ),
    instr(.VMLOAD,  ops1(.reg_eax),         Op3(0x0F, 0x01, 0xDA),   .ZO32, .R_Over32,      .{cpu.AMD_V} ),
    instr(.VMLOAD,  ops1(.reg_rax),         Op3(0x0F, 0x01, 0xDA),   .ZO64, .RM64,          .{No32, cpu.AMD_V} ),
// VMMCALL
    instr(.VMMCALL, ops0(),                 Op3(0x0F, 0x01, 0xD9),   .ZO, .ZO,              .{cpu.AMD_V} ),
// VMRUN
    instr(.VMRUN,   ops0(),                 Op3(0x0F, 0x01, 0xD8),   .ZO, .ZO,              .{cpu.AMD_V} ),
    instr(.VMRUN,   ops1(.reg_ax),          Op3(0x0F, 0x01, 0xD8),   .ZO16, .R_Over16,      .{No64, cpu.AMD_V} ),
    instr(.VMRUN,   ops1(.reg_eax),         Op3(0x0F, 0x01, 0xD8),   .ZO32, .R_Over32,      .{cpu.AMD_V} ),
    instr(.VMRUN,   ops1(.reg_rax),         Op3(0x0F, 0x01, 0xD8),   .ZO64, .RM64,          .{No32, cpu.AMD_V} ),
// VMSAVE
    instr(.VMSAVE,  ops0(),                 Op3(0x0F, 0x01, 0xDB),   .ZO, .ZO,              .{cpu.AMD_V} ),
    instr(.VMSAVE,  ops1(.reg_ax),          Op3(0x0F, 0x01, 0xDB),   .ZO16, .R_Over16,      .{No64, cpu.AMD_V} ),
    instr(.VMSAVE,  ops1(.reg_eax),         Op3(0x0F, 0x01, 0xDB),   .ZO32, .R_Over32,      .{cpu.AMD_V} ),
    instr(.VMSAVE,  ops1(.reg_rax),         Op3(0x0F, 0x01, 0xDB),   .ZO64, .RM64,          .{No32, cpu.AMD_V} ),

//
// Intel VT-x
//
// INVEPT
    instr(.INVEPT,   ops2(.reg32, .rm_mem128), preOp3(._66, 0x0F, 0x38, 0x80),   .M, .ZO,     .{No64, VT_x} ),
    instr(.INVEPT,   ops2(.reg64, .rm_mem128), preOp3(._66, 0x0F, 0x38, 0x80),   .M, .ZO,     .{No32, VT_x} ),
// INVVPID
    instr(.INVVPID,  ops2(.reg32, .rm_mem128), preOp3(._66, 0x0F, 0x38, 0x80),   .M, .ZO,     .{No64, VT_x} ),
    instr(.INVVPID,  ops2(.reg64, .rm_mem128), preOp3(._66, 0x0F, 0x38, 0x80),   .M, .ZO,     .{No32, VT_x} ),
// VMCLEAR
    instr(.VMCLEAR,  ops1(.rm_mem64),          preOp2r(._66, 0x0F, 0xC7, 6),     .M, .RM64,   .{VT_x} ),
// VMFUNC
    instr(.VMFUNC,   ops0(),                   preOp3(._NP, 0x0F, 0x01, 0xD4),   .ZO, .ZO,    .{VT_x} ),
// VMPTRLD
    instr(.VMPTRLD,  ops1(.rm_mem64),          preOp2r(._NP, 0x0F, 0xC7, 6),     .M, .RM64,   .{VT_x} ),
// VMPTRST
    instr(.VMPTRST,  ops1(.rm_mem64),          preOp2r(._NP, 0x0F, 0xC7, 7),     .M, .RM64,   .{VT_x} ),
// VMREAD
    instr(.VMREAD,   ops2(.rm32, .reg32),      preOp2(._NP, 0x0F, 0x78),         .MR, .RM32,  .{No64, VT_x} ),
    instr(.VMREAD,   ops2(.rm64, .reg64),      preOp2(._NP, 0x0F, 0x78),         .MR, .RM64,  .{No32, VT_x} ),
// VMWRITE
    instr(.VMWRITE,  ops2(.reg32, .rm32),      preOp2(._NP, 0x0F, 0x79),         .RM, .RM32,  .{No64, VT_x} ),
    instr(.VMWRITE,  ops2(.reg64, .rm64),      preOp2(._NP, 0x0F, 0x79),         .RM, .RM64,  .{No32, VT_x} ),
// VMCALL
    instr(.VMCALL,   ops0(),                      Op3(0x0F, 0x01, 0xC1),         .ZO, .ZO,    .{VT_x} ),
// VMLAUNCH
    instr(.VMLAUNCH, ops0(),                      Op3(0x0F, 0x01, 0xC2),         .ZO, .ZO,    .{VT_x} ),
// VMRESUME
    instr(.VMRESUME, ops0(),                      Op3(0x0F, 0x01, 0xC3),         .ZO, .ZO,    .{VT_x} ),
// VMXOFF
    instr(.VMXOFF,   ops0(),                      Op3(0x0F, 0x01, 0xC4),         .ZO, .ZO,    .{VT_x} ),
// VMXON
    instr(.VMXON,    ops1(.rm_mem64),             Op3r(0x0F, 0x01, 0xC7, 6),     .M, .RM64,   .{VT_x} ),

//
// SIMD legacy instructions (MMX + SSE)
//
// ADDPD
    instr(.ADDPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x58),     .RM, .ZO, .{SSE2} ),
// ADDPS
    instr(.ADDPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x58),     .RM, .ZO, .{SSE} ),
// ADDSD
    instr(.ADDSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x58),     .RM, .ZO, .{SSE2} ),
// ADDSS
    instr(.ADDSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x58),     .RM, .ZO, .{SSE} ),
// ADDSUBPD
    instr(.ADDSUBPD,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD0),     .RM, .ZO, .{SSE3} ),
// ADDSUBPS
    instr(.ADDSUBPS,  ops2(.xmml, .xmml_m128),      preOp2(._F2, 0x0F, 0xD0),     .RM, .ZO, .{SSE3} ),
// ANDPD
    instr(.ANDPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x54),     .RM, .ZO, .{SSE2} ),
// ANDPS
    instr(.ANDPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x54),     .RM, .ZO, .{SSE} ),
// ANDNPD
    instr(.ANDNPD,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x55),     .RM, .ZO, .{SSE2} ),
// ANDNPS
    instr(.ANDNPS,    ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x55),     .RM, .ZO, .{SSE} ),
// BLENDPD
    instr(.BLENDPD,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x0D),  .RMI, .ZO, .{SSE4_1} ),
// BLENDPS
    instr(.BLENDPS,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x0C),  .RMI, .ZO, .{SSE4_1} ),
// BLENDVPD
    instr(.BLENDVPD,  ops3(.xmml,.xmml_m128,.xmm0), preOp3(._66,0x0F,0x38,0x15),  .RM, .ZO, .{SSE4_1} ),
    instr(.BLENDVPD,  ops2(.xmml,.xmml_m128),       preOp3(._66,0x0F,0x38,0x15),  .RM, .ZO, .{SSE4_1} ),
// BLENDVPS
    instr(.BLENDVPS,  ops3(.xmml,.xmml_m128,.xmm0), preOp3(._66,0x0F,0x38,0x14),  .RM, .ZO, .{SSE4_1} ),
    instr(.BLENDVPS,  ops2(.xmml,.xmml_m128),       preOp3(._66,0x0F,0x38,0x14),  .RM, .ZO, .{SSE4_1} ),
// CMPPD
    instr(.CMPPD,     ops3(.xmml,.xmml_m128,.imm8), preOp2(._66, 0x0F, 0xC2),     .RMI, .ZO, .{SSE2} ),
// CMPPS
    instr(.CMPPS,     ops3(.xmml,.xmml_m128,.imm8), preOp2(._NP, 0x0F, 0xC2),     .RMI, .ZO, .{SSE} ),
// CMPSD
    instr(.CMPSD,     ops0(),                          Op1(0xA7),                 .ZO32, .RM32, .{_386} ), // overloaded with CMPS
    instr(.CMPSD,     ops3(.xmml,.xmml_m64,.imm8),  preOp2(._F2, 0x0F, 0xC2),     .RMI, .ZO, .{SSE2} ),
// CMPSS
    instr(.CMPSS,     ops3(.xmml,.xmml_m32,.imm8),  preOp2(._F3, 0x0F, 0xC2),     .RMI, .ZO, .{SSE} ),
// COMISD
    instr(.COMISD,    ops2(.xmml, .xmml_m64),       preOp2(._66, 0x0F, 0x2F),     .RM, .ZO, .{SSE2} ),
// COMISS
    instr(.COMISS,    ops2(.xmml, .xmml_m32),       preOp2(._NP, 0x0F, 0x2F),     .RM, .ZO, .{SSE} ),
// CVTDQ2PD
    instr(.CVTDQ2PD,  ops2(.xmml, .xmml_m64),       preOp2(._F3, 0x0F, 0xE6),     .RM, .ZO, .{SSE2} ),
// CVTDQ2PS
    instr(.CVTDQ2PS,  ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x5B),     .RM, .ZO, .{SSE2} ),
// CVTPD2DQ
    instr(.CVTPD2DQ,  ops2(.xmml, .xmml_m128),      preOp2(._F2, 0x0F, 0xE6),     .RM, .ZO, .{SSE2} ),
// CVTPD2PI
    instr(.CVTPD2PI,  ops2(.mm, .xmml_m128),        preOp2(._66, 0x0F, 0x2D),     .RM, .ZO, .{SSE2} ),
// CVTPD2PS
    instr(.CVTPD2PS,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5A),     .RM, .ZO, .{SSE2} ),
// CVTPI2PD
    instr(.CVTPI2PD,  ops2(.xmml, .mm_m64),         preOp2(._66, 0x0F, 0x2A),     .RM, .ZO, .{SSE2} ),
// CVTPI2PS
    instr(.CVTPI2PS,  ops2(.xmml, .mm_m64),         preOp2(._NP, 0x0F, 0x2A),     .RM, .ZO, .{SSE} ),
// CVTPS2DQ
    instr(.CVTPS2DQ,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5B),     .RM, .ZO, .{SSE2} ),
// CVTPS2PD
    instr(.CVTPS2PD,  ops2(.xmml, .xmml_m64),       preOp2(._NP, 0x0F, 0x5A),     .RM, .ZO, .{SSE2} ),
// CVTPS2PI
    instr(.CVTPS2PI,  ops2(.mm, .xmml_m64),         preOp2(._NP, 0x0F, 0x2D),     .RM, .ZO, .{SSE} ),
// CVTSD2SI
    instr(.CVTSD2SI,  ops2(.reg32, .xmml_m64),      preOp2(._F2, 0x0F, 0x2D),     .RM, .ZO,    .{SSE2} ),
    instr(.CVTSD2SI,  ops2(.reg64, .xmml_m64),      preOp2(._F2, 0x0F, 0x2D),     .RM, .REX_W, .{SSE2} ),
// CVTSD2SS
    instr(.CVTSD2SS,  ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x5A),     .RM, .ZO, .{SSE2} ),
// CVTSI2SD
    instr(.CVTSI2SD,  ops2(.xmml, .rm32),           preOp2(._F2, 0x0F, 0x2A),     .RM, .ZO,    .{SSE2} ),
    instr(.CVTSI2SD,  ops2(.xmml, .rm64),           preOp2(._F2, 0x0F, 0x2A),     .RM, .REX_W, .{SSE2} ),
// CVTSI2SS
    instr(.CVTSI2SS,  ops2(.xmml, .rm32),           preOp2(._F3, 0x0F, 0x2A),     .RM, .ZO,    .{SSE} ),
    instr(.CVTSI2SS,  ops2(.xmml, .rm64),           preOp2(._F3, 0x0F, 0x2A),     .RM, .REX_W, .{SSE} ),
// CVTSS2SD
    instr(.CVTSS2SD,  ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x5A),     .RM, .ZO, .{SSE2} ),
// CVTSS2SI
    instr(.CVTSS2SI,  ops2(.reg32, .xmml_m32),      preOp2(._F3, 0x0F, 0x2D),     .RM, .ZO,    .{SSE} ),
    instr(.CVTSS2SI,  ops2(.reg64, .xmml_m32),      preOp2(._F3, 0x0F, 0x2D),     .RM, .REX_W, .{SSE} ),
// CVTTPD2DQ
    instr(.CVTTPD2DQ, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE6),     .RM, .ZO, .{SSE2} ),
// CVTTPD2PI
    instr(.CVTTPD2PI, ops2(.mm, .xmml_m128),        preOp2(._66, 0x0F, 0x2C),     .RM, .ZO, .{SSE2} ),
// CVTTPS2DQ
    instr(.CVTTPS2DQ, ops2(.xmml, .xmml_m128),      preOp2(._F3, 0x0F, 0x5B),     .RM, .ZO, .{SSE2} ),
// CVTTPS2PI
    instr(.CVTTPS2PI, ops2(.mm, .xmml_m64),         preOp2(._NP, 0x0F, 0x2C),     .RM, .ZO, .{SSE} ),
// CVTTSD2SI
    instr(.CVTTSD2SI, ops2(.reg32, .xmml_m64),      preOp2(._F2, 0x0F, 0x2C),     .RM, .ZO,    .{SSE2} ),
    instr(.CVTTSD2SI, ops2(.reg64, .xmml_m64),      preOp2(._F2, 0x0F, 0x2C),     .RM, .REX_W, .{SSE2} ),
// CVTTSS2SI
    instr(.CVTTSS2SI, ops2(.reg32, .xmml_m32),      preOp2(._F3, 0x0F, 0x2C),     .RM, .ZO,    .{SSE} ),
    instr(.CVTTSS2SI, ops2(.reg64, .xmml_m32),      preOp2(._F3, 0x0F, 0x2C),     .RM, .REX_W, .{SSE} ),
// DIVPD
    instr(.DIVPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5E),     .RM, .ZO, .{SSE2} ),
// DIVPS
    instr(.DIVPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x5E),     .RM, .ZO, .{SSE} ),
// DIVSD
    instr(.DIVSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x5E),     .RM, .ZO, .{SSE2} ),
// DIVSS
    instr(.DIVSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x5E),     .RM, .ZO, .{SSE} ),
// DPPD
    instr(.DPPD,      ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x41),  .RMI,.ZO, .{SSE4_1} ),
// DPPS
    instr(.DPPS,      ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x40),  .RMI,.ZO, .{SSE4_1} ),
// EXTRACTPS
    instr(.EXTRACTPS, ops3(.rm32,.xmml,.imm8),      preOp3(._66,0x0F,0x3A,0x17),  .MRI,.ZO, .{SSE4_1} ),
    instr(.EXTRACTPS, ops3(.reg64,.xmml,.imm8),     preOp3(._66,0x0F,0x3A,0x17),  .MRI,.ZO, .{SSE4_1, No32} ),
// HADDPD
    instr(.HADDPD,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x7C),     .RM, .ZO, .{SSE3} ),
// HADDPS
    instr(.HADDPS,    ops2(.xmml, .xmml_m128),      preOp2(._F2, 0x0F, 0x7C),     .RM, .ZO, .{SSE3} ),
// HSUBPD
    instr(.HSUBPD,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x7D),     .RM, .ZO, .{SSE3} ),
// HSUBPS
    instr(.HSUBPS,    ops2(.xmml, .xmml_m128),      preOp2(._F2, 0x0F, 0x7D),     .RM, .ZO, .{SSE3} ),
// INSERTPS
    instr(.INSERTPS,  ops3(.xmml,.xmml_m32,.imm8),  preOp3(._66,0x0F,0x3A,0x21),  .RMI,.ZO, .{SSE4_1} ),
// LDDQU
    instr(.LDDQU,     ops2(.xmml, .rm_mem128),      preOp2(._F2, 0x0F, 0xF0),     .RM, .ZO, .{SSE3} ),
// MASKMOVDQU
    instr(.MASKMOVDQU,ops2(.xmml, .xmml),           preOp2(._66, 0x0F, 0xF7),     .RM, .ZO, .{SSE2} ),
// MASKMOVQ
    instr(.MASKMOVQ,  ops2(.mm, .mm),               preOp2(._NP, 0x0F, 0xF7),     .RM, .ZO, .{SSE} ),
// MAXPD
    instr(.MAXPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5F),     .RM, .ZO, .{SSE2} ),
// MAXPS
    instr(.MAXPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x5F),     .RM, .ZO, .{SSE} ),
// MAXSD
    instr(.MAXSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x5F),     .RM, .ZO, .{SSE2} ),
// MAXSS
    instr(.MAXSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x5F),     .RM, .ZO, .{SSE} ),
// MINPD
    instr(.MINPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5D),     .RM, .ZO, .{SSE2} ),
// MINPS
    instr(.MINPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x5D),     .RM, .ZO, .{SSE} ),
// MINSD
    instr(.MINSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x5D),     .RM, .ZO, .{SSE2} ),
// MINSS
    instr(.MINSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x5D),     .RM, .ZO, .{SSE} ),
// MOVAPD
    instr(.MOVAPD,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x28),     .RM, .ZO, .{SSE2} ),
    instr(.MOVAPD,    ops2(.xmml_m128, .xmml),      preOp2(._66, 0x0F, 0x29),     .MR, .ZO, .{SSE2} ),
// MOVAPS
    instr(.MOVAPS,    ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x28),     .RM, .ZO, .{SSE} ),
    instr(.MOVAPS,    ops2(.xmml_m128, .xmml),      preOp2(._NP, 0x0F, 0x29),     .MR, .ZO, .{SSE} ),
// MOVD / MOVQ / MOVQ (2)
    instr(.MOVD,      ops2(.mm, .rm32),             preOp2(._NP, 0x0F, 0x6E),     .RM, .ZO,    .{MMX} ),
    instr(.MOVD,      ops2(.rm32, .mm),             preOp2(._NP, 0x0F, 0x7E),     .MR, .ZO,    .{MMX} ),
    instr(.MOVD,      ops2(.mm, .rm64),             preOp2(._NP, 0x0F, 0x6E),     .RM, .REX_W, .{MMX} ),
    instr(.MOVD,      ops2(.rm64, .mm),             preOp2(._NP, 0x0F, 0x7E),     .MR, .REX_W, .{MMX} ),
    // xmm
    instr(.MOVD,      ops2(.xmml, .rm32),           preOp2(._66, 0x0F, 0x6E),     .RM, .ZO,    .{SSE2} ),
    instr(.MOVD,      ops2(.rm32, .xmml),           preOp2(._66, 0x0F, 0x7E),     .MR, .ZO,    .{SSE2} ),
    instr(.MOVD,      ops2(.xmml, .rm64),           preOp2(._66, 0x0F, 0x6E),     .RM, .REX_W, .{SSE2} ),
    instr(.MOVD,      ops2(.rm64, .xmml),           preOp2(._66, 0x0F, 0x7E),     .MR, .REX_W, .{SSE2} ),
    // MOVQ
    instr(.MOVQ,      ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x6F),     .RM, .ZO,    .{MMX} ),
    instr(.MOVQ,      ops2(.mm_m64, .mm),           preOp2(._NP, 0x0F, 0x7F),     .MR, .ZO,    .{MMX} ),
    instr(.MOVQ,      ops2(.mm, .rm64),             preOp2(._NP, 0x0F, 0x6E),     .RM, .REX_W, .{MMX} ),
    instr(.MOVQ,      ops2(.rm64, .mm),             preOp2(._NP, 0x0F, 0x7E),     .MR, .REX_W, .{MMX} ),
    // xmm
    instr(.MOVQ,      ops2(.xmml, .xmml_m64),       preOp2(._F3, 0x0F, 0x7E),     .RM, .ZO,    .{SSE2} ),
    instr(.MOVQ,      ops2(.xmml_m64, .xmml),       preOp2(._66, 0x0F, 0xD6),     .MR, .ZO,    .{SSE2} ),
    instr(.MOVQ,      ops2(.xmml, .rm64),           preOp2(._66, 0x0F, 0x6E),     .RM, .REX_W, .{SSE2} ),
    instr(.MOVQ,      ops2(.rm64, .xmml),           preOp2(._66, 0x0F, 0x7E),     .MR, .REX_W, .{SSE2} ),
// MOVDQA
    instr(.MOVDDUP,   ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x12),     .RM, .ZO, .{SSE3} ),
// MOVDQA
    instr(.MOVDQA,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x6F),     .RM, .ZO, .{SSE2} ),
    instr(.MOVDQA,    ops2(.xmml_m128, .xmml),      preOp2(._66, 0x0F, 0x7F),     .MR, .ZO, .{SSE2} ),
// MOVDQU
    instr(.MOVDQU,    ops2(.xmml, .xmml_m128),      preOp2(._F3, 0x0F, 0x6F),     .RM, .ZO, .{SSE2} ),
    instr(.MOVDQU,    ops2(.xmml_m128, .xmml),      preOp2(._F3, 0x0F, 0x7F),     .MR, .ZO, .{SSE2} ),
// MOVDQ2Q
    instr(.MOVDQ2Q,   ops2(.mm, .xmml),             preOp2(._F2, 0x0F, 0xD6),     .RM, .ZO, .{SSE2} ),
// MOVHLPS
    instr(.MOVHLPS,   ops2(.xmml, .xmml),           preOp2(._NP, 0x0F, 0x12),     .RM, .ZO, .{SSE} ),
// MOVHPD
    instr(.MOVHPD,    ops2(.xmml, .rm_mem64),       preOp2(._66, 0x0F, 0x16),     .RM, .ZO, .{SSE2} ),
// MOVHPS
    instr(.MOVHPS,    ops2(.xmml, .rm_mem64),       preOp2(._NP, 0x0F, 0x16),     .RM, .ZO, .{SSE} ),
// MOVLHPS
    instr(.MOVLHPS,   ops2(.xmml, .xmml),           preOp2(._NP, 0x0F, 0x16),     .RM, .ZO, .{SSE} ),
// MOVLPD
    instr(.MOVLPD,    ops2(.xmml, .rm_mem64),       preOp2(._66, 0x0F, 0x12),     .RM, .ZO, .{SSE2} ),
// MOVLPS
    instr(.MOVLPS,    ops2(.xmml, .rm_mem64),       preOp2(._NP, 0x0F, 0x12),     .RM, .ZO, .{SSE} ),
// MOVMSKPD
    instr(.MOVMSKPD,  ops2(.reg32, .xmml),          preOp2(._66, 0x0F, 0x50),     .RM, .ZO, .{SSE2} ),
    instr(.MOVMSKPD,  ops2(.reg64, .xmml),          preOp2(._66, 0x0F, 0x50),     .RM, .ZO, .{No32, SSE2} ),
// MOVMSKPS
    instr(.MOVMSKPS,  ops2(.reg32, .xmml),          preOp2(._NP, 0x0F, 0x50),     .RM, .ZO, .{SSE} ),
    instr(.MOVMSKPS,  ops2(.reg64, .xmml),          preOp2(._NP, 0x0F, 0x50),     .RM, .ZO, .{No32, SSE2} ),
// MOVNTDQA
    instr(.MOVNTDQA,  ops2(.xmml, .rm_mem128),      preOp3(._66, 0x0F,0x38,0x2A), .RM, .ZO, .{SSE4_1} ),
// MOVNTDQ
    instr(.MOVNTDQ,   ops2(.rm_mem128, .xmml),      preOp2(._66, 0x0F, 0xE7),     .MR, .ZO, .{SSE2} ),
// MOVNTPD
    instr(.MOVNTPD,   ops2(.rm_mem128, .xmml),      preOp2(._66, 0x0F, 0x2B),     .MR, .ZO, .{SSE2} ),
// MOVNTPS
    instr(.MOVNTPS,   ops2(.rm_mem128, .xmml),      preOp2(._NP, 0x0F, 0x2B),     .MR, .ZO, .{SSE} ),
// MOVNTQ
    instr(.MOVNTQ,    ops2(.rm_mem64, .mm),         preOp2(._NP, 0x0F, 0xE7),     .MR, .ZO, .{SSE} ),
// MOVQ2DQ
    instr(.MOVQ2DQ,   ops2(.xmml, .mm),             preOp2(._F3, 0x0F, 0xD6),     .RM, .ZO, .{SSE2} ),
// MOVSD
    instr(.MOVSD,     ops0(),                       Op1(0xA5),                    .ZO32, .RM32, .{_386} ), // overloaded
    instr(.MOVSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x10),     .RM, .ZO, .{SSE2} ),
    instr(.MOVSD,     ops2(.xmml_m64, .xmml),       preOp2(._F2, 0x0F, 0x11),     .MR, .ZO, .{SSE2} ),
// MOVSHDUP
    instr(.MOVSHDUP,  ops2(.xmml, .xmml_m128),      preOp2(._F3, 0x0F, 0x16),     .RM, .ZO, .{SSE3} ),
// MOVSLDUP
    instr(.MOVSLDUP,  ops2(.xmml, .xmml_m128),      preOp2(._F3, 0x0F, 0x12),     .RM, .ZO, .{SSE3} ),
// MOVSS
    instr(.MOVSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x10),     .RM, .ZO, .{SSE} ),
    instr(.MOVSS,     ops2(.xmml_m32, .xmml),       preOp2(._F3, 0x0F, 0x11),     .MR, .ZO, .{SSE} ),
// MOVUPD
    instr(.MOVUPD,    ops2(.xmml, .xmml_m64),       preOp2(._66, 0x0F, 0x10),     .RM, .ZO, .{SSE2} ),
    instr(.MOVUPD,    ops2(.xmml_m64, .xmml),       preOp2(._66, 0x0F, 0x11),     .MR, .ZO, .{SSE2} ),
// MOVUPS
    instr(.MOVUPS,    ops2(.xmml, .xmml_m32),       preOp2(._NP, 0x0F, 0x10),     .RM, .ZO, .{SSE} ),
    instr(.MOVUPS,    ops2(.xmml_m32, .xmml),       preOp2(._NP, 0x0F, 0x11),     .MR, .ZO, .{SSE} ),
// MPSADBW
    instr(.MPSADBW,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66, 0x0F,0x3A,0x42), .RMI,.ZO, .{SSE4_1} ),
// MULPD
    instr(.MULPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x59),     .RM, .ZO, .{SSE2} ),
// MULPS
    instr(.MULPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x59),     .RM, .ZO, .{SSE} ),
// MULSD
    instr(.MULSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x59),     .RM, .ZO, .{SSE2} ),
// MULSS
    instr(.MULSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x59),     .RM, .ZO, .{SSE} ),
// ORPD
    instr(.ORPD,      ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x56),     .RM, .ZO, .{SSE2} ),
// ORPS
    instr(.ORPS,      ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x56),     .RM, .ZO, .{SSE} ),
// PABSB / PABSW /PABSD
    // PABSB
    instr(.PABSB,     ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x1C), .RM, .ZO, .{SSSE3} ),
    instr(.PABSB,     ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x1C), .RM, .ZO, .{SSSE3} ),
    // PABSW
    instr(.PABSW,     ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x1D), .RM, .ZO, .{SSSE3} ),
    instr(.PABSW,     ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x1D), .RM, .ZO, .{SSSE3} ),
    // PABSD
    instr(.PABSD,     ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x1E), .RM, .ZO, .{SSSE3} ),
    instr(.PABSD,     ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x1E), .RM, .ZO, .{SSSE3} ),
// PACKSSWB / PACKSSDW
    instr(.PACKSSWB,  ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x63),     .RM, .ZO, .{MMX} ),
    instr(.PACKSSWB,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x63),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PACKSSDW,  ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x6B),     .RM, .ZO, .{MMX} ),
    instr(.PACKSSDW,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x6B),     .RM, .ZO, .{SSE2} ),
// PACKUSWB
    instr(.PACKUSWB,  ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x67),     .RM, .ZO, .{MMX} ),
    instr(.PACKUSWB,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x67),     .RM, .ZO, .{SSE2} ),
// PACKUSDW
    instr(.PACKUSDW,  ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F, 0x38,0x2B),.RM, .ZO, .{SSE4_1} ),
// PADDB / PADDW / PADDD / PADDQ
    instr(.PADDB,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xFC),     .RM, .ZO, .{MMX} ),
    instr(.PADDB,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xFC),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PADDW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xFD),     .RM, .ZO, .{MMX} ),
    instr(.PADDW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xFD),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PADDD,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xFE),     .RM, .ZO, .{MMX} ),
    instr(.PADDD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xFE),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PADDQ,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD4),     .RM, .ZO, .{MMX} ),
    instr(.PADDQ,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD4),     .RM, .ZO, .{SSE2} ),
// PADDSB / PADDSW
    instr(.PADDSB,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xEC),     .RM, .ZO, .{MMX} ),
    instr(.PADDSB,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xEC),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PADDSW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xED),     .RM, .ZO, .{MMX} ),
    instr(.PADDSW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xED),     .RM, .ZO, .{SSE2} ),
// PADDUSB / PADDSW
    instr(.PADDUSB,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDC),     .RM, .ZO, .{MMX} ),
    instr(.PADDUSB,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDC),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PADDUSW,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDD),     .RM, .ZO, .{MMX} ),
    instr(.PADDUSW,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDD),     .RM, .ZO, .{SSE2} ),
// PALIGNR
    instr(.PALIGNR,   ops3(.mm,.mm_m64,.imm8),      preOp3(._NP,0x0F,0x3A,0x0F),  .RMI,.ZO, .{SSSE3} ),
    instr(.PALIGNR,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x0F),  .RMI,.ZO, .{SSSE3} ),
// PAND
    instr(.PAND,      ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDB),     .RM, .ZO, .{MMX} ),
    instr(.PAND,      ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDB),     .RM, .ZO, .{SSE2} ),
// PANDN
    instr(.PANDN,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDF),     .RM, .ZO, .{MMX} ),
    instr(.PANDN,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDF),     .RM, .ZO, .{SSE2} ),
// PAVGB / PAVGW
    instr(.PAVGB,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE0),     .RM, .ZO, .{SSE} ),
    instr(.PAVGB,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE0),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PAVGW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE3),     .RM, .ZO, .{SSE} ),
    instr(.PAVGW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE3),     .RM, .ZO, .{SSE2} ),
// PBLENDVB
    instr(.PBLENDVB,  ops3(.xmml,.xmml_m128,.xmm0), preOp3(._66,0x0F,0x38,0x10),  .RM, .ZO, .{SSE4_1} ),
    instr(.PBLENDVB,  ops2(.xmml,.xmml_m128),       preOp3(._66,0x0F,0x38,0x10),  .RM, .ZO, .{SSE4_1} ),
// PBLENDVW
    instr(.PBLENDW,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x0E),  .RMI,.ZO, .{SSE4_1} ),
// PCLMULQDQ
    instr(.PCLMULQDQ, ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x44),  .RMI,.ZO, .{PCLMULQDQ} ),
// PCMPEQB / PCMPEQW / PCMPEQD
    instr(.PCMPEQB,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x74),     .RM, .ZO, .{MMX} ),
    instr(.PCMPEQB,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x74),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PCMPEQW,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x75),     .RM, .ZO, .{MMX} ),
    instr(.PCMPEQW,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x75),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PCMPEQD,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x76),     .RM, .ZO, .{MMX} ),
    instr(.PCMPEQD,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x76),     .RM, .ZO, .{SSE2} ),
// PCMPEQQ
    instr(.PCMPEQQ,   ops2(.xmml, .xmml_m128),      preOp3(._66,0x0F,0x38,0x29),  .RM, .ZO, .{SSE2} ),
// PCMPESTRI
    instr(.PCMPESTRI, ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x61),  .RMI,.ZO, .{SSE4_2} ),
// PCMPESTRM
    instr(.PCMPESTRM, ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x60),  .RMI,.ZO, .{SSE4_2} ),
// PCMPGTB / PCMPGTW / PCMPGTD
    instr(.PCMPGTB,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x64),     .RM, .ZO, .{MMX} ),
    instr(.PCMPGTB,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x64),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PCMPGTW,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x65),     .RM, .ZO, .{MMX} ),
    instr(.PCMPGTW,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x65),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PCMPGTD,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x66),     .RM, .ZO, .{MMX} ),
    instr(.PCMPGTD,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x66),     .RM, .ZO, .{SSE2} ),
// PCMPISTRI
    instr(.PCMPISTRI, ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x63),  .RMI,.ZO, .{SSE4_2} ),
// PCMPISTRM
    instr(.PCMPISTRM, ops3(.xmml,.xmml_m128,.imm8), preOp3(._66,0x0F,0x3A,0x62),  .RMI,.ZO, .{SSE4_2} ),
// PEXTRB / PEXTRD / PEXTRQ
    instr(.PEXTRB,    ops3(.rm_mem8, .xmml, .imm8), preOp3(._66,0x0F,0x3A,0x14),  .MRI,.ZO, .{SSE4_1} ),
    instr(.PEXTRB,    ops3(.reg32, .xmml, .imm8),   preOp3(._66,0x0F,0x3A,0x14),  .MRI,.ZO, .{SSE4_1} ),
    instr(.PEXTRB,    ops3(.reg64, .xmml, .imm8),   preOp3(._66,0x0F,0x3A,0x14),  .MRI,.ZO, .{SSE4_1, No32} ),
    instr(.PEXTRD,    ops3(.rm32, .xmml, .imm8),    preOp3(._66,0x0F,0x3A,0x16),  .MRI,.ZO, .{SSE4_1} ),
    instr(.PEXTRQ,    ops3(.rm64, .xmml, .imm8),    preOp3(._66,0x0F,0x3A,0x16),  .MRI,.REX_W, .{SSE4_1} ),
// PEXTRW
    instr(.PEXTRW,    ops3(.reg16, .mm, .imm8),     preOp2(._NP,0x0F,0xC5),       .RMI,.ZO, .{SSE} ),
    instr(.PEXTRW,    ops3(.reg32, .mm, .imm8),     preOp2(._NP,0x0F,0xC5),       .RMI,.ZO, .{SSE} ),
    instr(.PEXTRW,    ops3(.reg64, .mm, .imm8),     preOp2(._NP,0x0F,0xC5),       .RMI,.ZO, .{SSE, No32} ),
    instr(.PEXTRW,    ops3(.reg16, .xmml, .imm8),   preOp2(._66,0x0F,0xC5),       .RMI,.ZO, .{SSE2} ),
    instr(.PEXTRW,    ops3(.reg32, .xmml, .imm8),   preOp2(._66,0x0F,0xC5),       .RMI,.ZO, .{SSE2} ),
    instr(.PEXTRW,    ops3(.reg64, .xmml, .imm8),   preOp2(._66,0x0F,0xC5),       .RMI,.ZO, .{SSE2, No32} ),
    instr(.PEXTRW,    ops3(.rm16, .xmml, .imm8),    preOp3(._66,0x0F,0x3A,0x15),  .MRI,.ZO, .{SSE4_1} ),
    instr(.PEXTRW,    ops3(.rm_reg32, .xmml, .imm8),preOp3(._66,0x0F,0x3A,0x15),  .MRI,.ZO, .{SSE4_1} ),
    instr(.PEXTRW,    ops3(.rm_reg64, .xmml, .imm8),preOp3(._66,0x0F,0x3A,0x15),  .MRI,.ZO, .{SSE4_1, No32} ),
// PHADDW / PHADDD
    instr(.PHADDW,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x01), .RM, .ZO, .{SSSE3} ),
    instr(.PHADDW,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x01), .RM, .ZO, .{SSSE3} ),
    instr(.PHADDD,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x02), .RM, .ZO, .{SSSE3} ),
    instr(.PHADDD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x02), .RM, .ZO, .{SSSE3} ),
// PHADDSW
    instr(.PHADDSW,   ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x03), .RM, .ZO, .{SSSE3} ),
    instr(.PHADDSW,   ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x03), .RM, .ZO, .{SSSE3} ),
// PHMINPOSUW
    instr(.PHMINPOSUW,ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x41), .RM, .ZO, .{SSE4_1} ),
// PHSUBW / PHSUBD
    instr(.PHSUBW,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x05), .RM, .ZO, .{SSSE3} ),
    instr(.PHSUBW,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x05), .RM, .ZO, .{SSSE3} ),
    instr(.PHSUBD,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x06), .RM, .ZO, .{SSSE3} ),
    instr(.PHSUBD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x06), .RM, .ZO, .{SSSE3} ),
// PHSUBSW
    instr(.PHSUBSW,   ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x07), .RM, .ZO, .{SSSE3} ),
    instr(.PHSUBSW,   ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x07), .RM, .ZO, .{SSSE3} ),
// PINSRB / PINSRD / PINSRQ
    instr(.PINSRB,    ops3(.xmml, .rm_mem8, .imm8), preOp3(._66,0x0F,0x3A,0x20),  .RMI,.ZO, .{SSE4_1} ),
    instr(.PINSRB,    ops3(.xmml, .rm_reg32, .imm8),preOp3(._66,0x0F,0x3A,0x20),  .RMI,.ZO, .{SSE4_1} ),
    //
    instr(.PINSRD,    ops3(.xmml, .rm32, .imm8),    preOp3(._66,0x0F,0x3A,0x22),  .RMI,.ZO, .{SSE4_1} ),
    //
    instr(.PINSRQ,    ops3(.xmml, .rm64, .imm8),    preOp3(._66,0x0F,0x3A,0x22),  .RMI,.REX_W, .{SSE4_1} ),
// PINSRW
    instr(.PINSRW,    ops3(.mm, .rm_mem16, .imm8),  preOp2(._NP, 0x0F, 0xC4),     .RMI,.ZO, .{SSE} ),
    instr(.PINSRW,    ops3(.mm, .rm_reg32, .imm8),  preOp2(._NP, 0x0F, 0xC4),     .RMI,.ZO, .{SSE} ),
    instr(.PINSRW,    ops3(.xmml, .rm_mem16, .imm8),preOp2(._66, 0x0F, 0xC4),     .RMI,.ZO, .{SSE2} ),
    instr(.PINSRW,    ops3(.xmml, .rm_reg32, .imm8),preOp2(._66, 0x0F, 0xC4),     .RMI,.ZO, .{SSE2} ),
// PMADDUBSW
    instr(.PMADDUBSW, ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x04), .RM, .ZO, .{SSSE3} ),
    instr(.PMADDUBSW, ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x04), .RM, .ZO, .{SSSE3} ),
// PMADDWD
    instr(.PMADDWD,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF5),     .RM, .ZO, .{MMX} ),
    instr(.PMADDWD,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF5),     .RM, .ZO, .{SSE2} ),
// PMAXSB / PMAXSW / PMAXSD
    instr(.PMAXSW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xEE),     .RM, .ZO, .{SSE} ),
    instr(.PMAXSW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xEE),     .RM, .ZO, .{SSE2} ),
    instr(.PMAXSB,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3C), .RM, .ZO, .{SSE4_1} ),
    instr(.PMAXSD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3D), .RM, .ZO, .{SSE4_1} ),
// PMAXUB / PMAXUW
    instr(.PMAXUB,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDE),     .RM, .ZO, .{SSE} ),
    instr(.PMAXUB,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDE),     .RM, .ZO, .{SSE2} ),
    instr(.PMAXUW,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3E), .RM, .ZO, .{SSE4_1} ),
// PMAXUD
    instr(.PMAXUD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3F), .RM, .ZO, .{SSE4_1} ),
// PMINSB / PMINSW
    instr(.PMINSW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xEA),     .RM, .ZO, .{SSE} ),
    instr(.PMINSW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xEA),     .RM, .ZO, .{SSE2} ),
    instr(.PMINSB,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x38), .RM, .ZO, .{SSE4_1} ),
// PMINSD
    instr(.PMINSD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x39), .RM, .ZO, .{SSE4_1} ),
// PMINUB / PMINUW
    instr(.PMINUB,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xDA),     .RM, .ZO, .{SSE} ),
    instr(.PMINUB,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xDA),     .RM, .ZO, .{SSE2} ),
    instr(.PMINUW,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3A), .RM, .ZO, .{SSE4_1} ),
// PMINUD
    instr(.PMINUD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x3B), .RM, .ZO, .{SSE4_1} ),
// PMOVMSKB
    instr(.PMOVMSKB,  ops2(.reg32, .rm_mm),         preOp2(._NP, 0x0F, 0xD7),     .RM, .ZO, .{SSE} ),
    instr(.PMOVMSKB,  ops2(.reg64, .rm_mm),         preOp2(._NP, 0x0F, 0xD7),     .RM, .ZO, .{SSE} ),
    instr(.PMOVMSKB,  ops2(.reg32, .rm_xmml),       preOp2(._66, 0x0F, 0xD7),     .RM, .ZO, .{SSE} ),
    instr(.PMOVMSKB,  ops2(.reg64, .rm_xmml),       preOp2(._66, 0x0F, 0xD7),     .RM, .ZO, .{SSE} ),
// PMOVSX
    instr(.PMOVSXBW,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x20), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVSXBD,  ops2(.xmml, .xmml_m32),       preOp3(._66, 0x0F,0x38,0x21), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVSXBQ,  ops2(.xmml, .xmml_m16),       preOp3(._66, 0x0F,0x38,0x22), .RM, .ZO, .{SSE4_1} ),
    //
    instr(.PMOVSXWD,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x23), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVSXWQ,  ops2(.xmml, .xmml_m32),       preOp3(._66, 0x0F,0x38,0x24), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVSXDQ,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x25), .RM, .ZO, .{SSE4_1} ),
// PMOVZX
    instr(.PMOVZXBW,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x30), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVZXBD,  ops2(.xmml, .xmml_m32),       preOp3(._66, 0x0F,0x38,0x31), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVZXBQ,  ops2(.xmml, .xmml_m16),       preOp3(._66, 0x0F,0x38,0x32), .RM, .ZO, .{SSE4_1} ),
    //
    instr(.PMOVZXWD,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x33), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVZXWQ,  ops2(.xmml, .xmml_m32),       preOp3(._66, 0x0F,0x38,0x34), .RM, .ZO, .{SSE4_1} ),
    instr(.PMOVZXDQ,  ops2(.xmml, .xmml_m64),       preOp3(._66, 0x0F,0x38,0x35), .RM, .ZO, .{SSE4_1} ),
// PMULDQ
    instr(.PMULDQ,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x28), .RM, .ZO, .{SSE4_1} ),
// PMULHRSW
    instr(.PMULHRSW,  ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x0B), .RM, .ZO, .{SSSE3} ),
    instr(.PMULHRSW,  ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x0B), .RM, .ZO, .{SSSE3} ),
// PMULHUW
    instr(.PMULHUW,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE4),     .RM, .ZO, .{SSE} ),
    instr(.PMULHUW,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE4),     .RM, .ZO, .{SSE2} ),
// PMULHW
    instr(.PMULHW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE5),     .RM, .ZO, .{MMX} ),
    instr(.PMULHW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE5),     .RM, .ZO, .{SSE2} ),
// PMULLD
    instr(.PMULLD,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x40), .RM, .ZO, .{SSE4_1} ),
// PMULLW
    instr(.PMULLW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD5),     .RM, .ZO, .{MMX} ),
    instr(.PMULLW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD5),     .RM, .ZO, .{SSE2} ),
// PMULUDQ
    instr(.PMULUDQ,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF4),     .RM, .ZO, .{SSE2} ),
    instr(.PMULUDQ,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF4),     .RM, .ZO, .{SSE2} ),
// POR
    instr(.POR,       ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xEB),     .RM, .ZO, .{MMX} ),
    instr(.POR,       ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xEB),     .RM, .ZO, .{SSE2} ),
// PSADBW
    instr(.PSADBW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF6),     .RM, .ZO, .{SSE} ),
    instr(.PSADBW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF6),     .RM, .ZO, .{SSE2} ),
// PSHUFB
    instr(.PSHUFB,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x00), .RM, .ZO, .{SSSE3} ),
    instr(.PSHUFB,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x00), .RM, .ZO, .{SSSE3} ),
// PSHUFD
    instr(.PSHUFD,    ops3(.xmml,.xmml_m128,.imm8), preOp2(._66, 0x0F, 0x70),     .RMI,.ZO, .{SSE2} ),
// PSHUFHW
    instr(.PSHUFHW,   ops3(.xmml,.xmml_m128,.imm8), preOp2(._F3, 0x0F, 0x70),     .RMI,.ZO, .{SSE2} ),
// PSHUFLW
    instr(.PSHUFLW,   ops3(.xmml,.xmml_m128,.imm8), preOp2(._F2, 0x0F, 0x70),     .RMI,.ZO, .{SSE2} ),
// PSHUFW
    instr(.PSHUFW,    ops3(.mm, .mm_m64, .imm8),    preOp2(._NP, 0x0F, 0x70),     .RMI,.ZO, .{SSE} ),
// PSIGNB / PSIGNW / PSIGND
    instr(.PSIGNB,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x08), .RM, .ZO, .{SSSE3} ),
    instr(.PSIGNB,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x08), .RM, .ZO, .{SSSE3} ),
    //
    instr(.PSIGNW,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x09), .RM, .ZO, .{SSSE3} ),
    instr(.PSIGNW,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x09), .RM, .ZO, .{SSSE3} ),
    //
    instr(.PSIGND,    ops2(.mm, .mm_m64),           preOp3(._NP, 0x0F,0x38,0x0A), .RM, .ZO, .{SSSE3} ),
    instr(.PSIGND,    ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x0A), .RM, .ZO, .{SSSE3} ),
// PSLLDQ
    instr(.PSLLDQ,    ops2(.rm_xmml, .imm8),        preOp2r(._66, 0x0F, 0x73, 7), .MI, .ZO, .{SSE2} ),
// PSLLW / PSLLD / PSLLQ
    // PSLLW
    instr(.PSLLW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF1),     .RM, .ZO, .{MMX} ),
    instr(.PSLLW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF1),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSLLW,     ops2(.rm_mm, .imm8),          preOp2r(._NP, 0x0F, 0x71, 6), .MI, .ZO, .{MMX} ),
    instr(.PSLLW,     ops2(.rm_xmml, .imm8),        preOp2r(._66, 0x0F, 0x71, 6), .MI, .ZO, .{SSE2} ),
    // PSLLD
    instr(.PSLLD,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF2),     .RM, .ZO, .{MMX} ),
    instr(.PSLLD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF2),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSLLD,     ops2(.rm_mm, .imm8),          preOp2r(._NP, 0x0F, 0x72, 6), .MI, .ZO, .{MMX} ),
    instr(.PSLLD,     ops2(.rm_xmml, .imm8),        preOp2r(._66, 0x0F, 0x72, 6), .MI, .ZO, .{SSE2} ),
    // PSLLQ
    instr(.PSLLQ,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF3),     .RM, .ZO, .{MMX} ),
    instr(.PSLLQ,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF3),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSLLQ,     ops2(.rm_mm, .imm8),          preOp2r(._NP, 0x0F, 0x73, 6), .MI, .ZO, .{MMX} ),
    instr(.PSLLQ,     ops2(.rm_xmml, .imm8),        preOp2r(._66, 0x0F, 0x73, 6), .MI, .ZO, .{SSE2} ),
// PSRAW / PSRAD
    // PSRAW
    instr(.PSRAW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE1),     .RM, .ZO, .{MMX} ),
    instr(.PSRAW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE1),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSRAW,     ops2(.mm, .imm8),             preOp2r(._NP, 0x0F, 0x71, 4), .MI, .ZO, .{MMX} ),
    instr(.PSRAW,     ops2(.xmml, .imm8),           preOp2r(._66, 0x0F, 0x71, 4), .MI, .ZO, .{SSE2} ),
    // PSRAD
    instr(.PSRAD,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE2),     .RM, .ZO, .{MMX} ),
    instr(.PSRAD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE2),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSRAD,     ops2(.mm, .imm8),             preOp2r(._NP, 0x0F, 0x72, 4), .MI, .ZO, .{MMX} ),
    instr(.PSRAD,     ops2(.xmml, .imm8),           preOp2r(._66, 0x0F, 0x72, 4), .MI, .ZO, .{SSE2} ),
// PSRLDQ
    instr(.PSRLDQ,    ops2(.rm_xmml, .imm8),        preOp2r(._66, 0x0F, 0x73, 3), .MI, .ZO, .{SSE2} ),
// PSRLW / PSRLD / PSRLQ
    // PSRLW
    instr(.PSRLW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD1),     .RM, .ZO, .{MMX} ),
    instr(.PSRLW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD1),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSRLW,     ops2(.mm, .imm8),             preOp2r(._NP, 0x0F, 0x71, 2), .MI, .ZO, .{MMX} ),
    instr(.PSRLW,     ops2(.xmml, .imm8),           preOp2r(._66, 0x0F, 0x71, 2), .MI, .ZO, .{SSE2} ),
    // PSRLD
    instr(.PSRLD,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD2),     .RM, .ZO, .{MMX} ),
    instr(.PSRLD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD2),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSRLD,     ops2(.mm, .imm8),             preOp2r(._NP, 0x0F, 0x72, 2), .MI, .ZO, .{MMX} ),
    instr(.PSRLD,     ops2(.xmml, .imm8),           preOp2r(._66, 0x0F, 0x72, 2), .MI, .ZO, .{SSE2} ),
    // PSRLQ
    instr(.PSRLQ,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD3),     .RM, .ZO, .{MMX} ),
    instr(.PSRLQ,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD3),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PSRLQ,     ops2(.mm, .imm8),             preOp2r(._NP, 0x0F, 0x73, 2), .MI, .ZO, .{MMX} ),
    instr(.PSRLQ,     ops2(.xmml, .imm8),           preOp2r(._66, 0x0F, 0x73, 2), .MI, .ZO, .{SSE2} ),
// PSUBB / PSUBW / PSUBD
    // PSUBB
    instr(.PSUBB,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF8),     .RM, .ZO, .{MMX} ),
    instr(.PSUBB,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF8),     .RM, .ZO, .{SSE2} ),
    // PSUBW
    instr(.PSUBW,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xF9),     .RM, .ZO, .{MMX} ),
    instr(.PSUBW,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xF9),     .RM, .ZO, .{SSE2} ),
    // PSUBD
    instr(.PSUBD,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xFA),     .RM, .ZO, .{MMX} ),
    instr(.PSUBD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xFA),     .RM, .ZO, .{SSE2} ),
// PSUBQ
    instr(.PSUBQ,     ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xFB),     .RM, .ZO, .{SSE2} ),
    instr(.PSUBQ,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xFB),     .RM, .ZO, .{SSE2} ),
// PSUBSB / PSUBSW
    // PSUBSB
    instr(.PSUBSB,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE8),     .RM, .ZO, .{MMX} ),
    instr(.PSUBSB,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE8),     .RM, .ZO, .{SSE2} ),
    // PSUBSW
    instr(.PSUBSW,    ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xE9),     .RM, .ZO, .{MMX} ),
    instr(.PSUBSW,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xE9),     .RM, .ZO, .{SSE2} ),
// PSUBUSB / PSUBUSW
    // PSUBUSB
    instr(.PSUBUSB,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD8),     .RM, .ZO, .{MMX} ),
    instr(.PSUBUSB,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD8),     .RM, .ZO, .{SSE2} ),
    // PSUBUSW
    instr(.PSUBUSW,   ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xD9),     .RM, .ZO, .{MMX} ),
    instr(.PSUBUSW,   ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xD9),     .RM, .ZO, .{SSE2} ),
// PTEST
    instr(.PTEST,     ops2(.xmml, .xmml_m128),      preOp3(._66, 0x0F,0x38,0x17), .RM, .ZO, .{SSE4_1} ),
// PUNPCKHBW / PUNPCKHWD / PUNPCKHDQ / PUNPCKHQDQ
    instr(.PUNPCKHBW, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x68),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKHBW, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x68),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKHWD, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x69),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKHWD, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x69),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKHDQ, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x6A),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKHDQ, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x6A),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKHQDQ,ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x6D),     .RM, .ZO, .{SSE2} ),
// PUNPCKLBW / PUNPCKLWD / PUNPCKLDQ / PUNPCKLQDQ
    instr(.PUNPCKLBW, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x60),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKLBW, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x60),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKLWD, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x61),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKLWD, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x61),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKLDQ, ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0x62),     .RM, .ZO, .{MMX} ),
    instr(.PUNPCKLDQ, ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x62),     .RM, .ZO, .{SSE2} ),
    //
    instr(.PUNPCKLQDQ,ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x6C),     .RM, .ZO, .{SSE2} ),
// PXOR
    instr(.PXOR,      ops2(.mm, .mm_m64),           preOp2(._NP, 0x0F, 0xEF),     .RM, .ZO, .{MMX} ),
    instr(.PXOR,      ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0xEF),     .RM, .ZO, .{SSE2} ),
// RCPPS
    instr(.RCPPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x53),     .RM, .ZO, .{SSE} ),
// RCPSS
    instr(.RCPSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x53),     .RM, .ZO, .{SSE} ),
// ROUNDPD
    instr(.ROUNDPD,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66, 0x0F,0x3A,0x09), .RMI,.ZO, .{SSE4_1} ),
// ROUNDPS
    instr(.ROUNDPS,   ops3(.xmml,.xmml_m128,.imm8), preOp3(._66, 0x0F,0x3A,0x08), .RMI,.ZO, .{SSE4_1} ),
// ROUNDSD
    instr(.ROUNDSD,   ops3(.xmml,.xmml_m64,.imm8),  preOp3(._66, 0x0F,0x3A,0x0B), .RMI,.ZO, .{SSE4_1} ),
// ROUNDSS
    instr(.ROUNDSS,   ops3(.xmml,.xmml_m32,.imm8),  preOp3(._66, 0x0F,0x3A,0x0A), .RMI,.ZO, .{SSE4_1} ),
// RSQRTPS
    instr(.RSQRTPS,   ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x52),     .RM, .ZO, .{SSE} ),
// RSQRTSS
    instr(.RSQRTSS,   ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x52),     .RM, .ZO, .{SSE} ),
// SHUFPD
    instr(.SHUFPD,    ops3(.xmml,.xmml_m128,.imm8), preOp2(._66, 0x0F, 0xC6),     .RMI,.ZO, .{SSE2} ),
// SHUFPS
    instr(.SHUFPS,    ops3(.xmml,.xmml_m128,.imm8), preOp2(._NP, 0x0F, 0xC6),     .RMI,.ZO, .{SSE} ),
// SQRTPD
    instr(.SQRTPD,    ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x51),     .RM, .ZO, .{SSE2} ),
// SQRTPS
    instr(.SQRTPS,    ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x51),     .RM, .ZO, .{SSE} ),
// SQRTSD
    instr(.SQRTSD,    ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x51),     .RM, .ZO, .{SSE2} ),
// SQRTSS
    instr(.SQRTSS,    ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x51),     .RM, .ZO, .{SSE} ),
// SUBPD
    instr(.SUBPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x5C),     .RM, .ZO, .{SSE2} ),
// SUBPS
    instr(.SUBPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x5C),     .RM, .ZO, .{SSE} ),
// SUBSD
    instr(.SUBSD,     ops2(.xmml, .xmml_m64),       preOp2(._F2, 0x0F, 0x5C),     .RM, .ZO, .{SSE2} ),
// SUBSS
    instr(.SUBSS,     ops2(.xmml, .xmml_m32),       preOp2(._F3, 0x0F, 0x5C),     .RM, .ZO, .{SSE} ),
// UCOMISD
    instr(.UCOMISD,   ops2(.xmml, .xmml_m64),       preOp2(._66, 0x0F, 0x2E),     .RM, .ZO, .{SSE2} ),
// UCOMISS
    instr(.UCOMISS,   ops2(.xmml, .xmml_m32),       preOp2(._NP, 0x0F, 0x2E),     .RM, .ZO, .{SSE} ),
// UNPCKHPD
    instr(.UNPCKHPD,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x15),     .RM, .ZO, .{SSE2} ),
// UNPCKHPS
    instr(.UNPCKHPS,  ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x15),     .RM, .ZO, .{SSE} ),
// UNPCKLPD
    instr(.UNPCKLPD,  ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x14),     .RM, .ZO, .{SSE2} ),
// UNPCKLPS
    instr(.UNPCKLPS,  ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x14),     .RM, .ZO, .{SSE} ),
// XORPD
    instr(.XORPD,     ops2(.xmml, .xmml_m128),      preOp2(._66, 0x0F, 0x57),     .RM, .ZO, .{SSE2} ),
// XORPS
    instr(.XORPS,     ops2(.xmml, .xmml_m128),      preOp2(._NP, 0x0F, 0x57),     .RM, .ZO, .{SSE} ),

//
// SIMD vector instructions (AVX, AVX2, AVX512)
//
// VADDPD
    instr(.VADDPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x58),   .RVM, .ZO, .{AVX} ),
    instr(.VADDPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x58),   .RVM, .ZO, .{AVX} ),
    instr(.VADDPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x58),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VADDPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x58),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VADDPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_er),  evex(.L512,._66,._0F,.W1,  0x58),   .RVM, .ZO, .{AVX512F} ),
// VADDPS
    instr(.VADDPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x58),   .RVM, .ZO, .{AVX} ),
    instr(.VADDPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x58),   .RVM, .ZO, .{AVX} ),
    instr(.VADDPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x58),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VADDPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x58),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VADDPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_er),  evex(.L512,._NP,._0F,.W0,  0x58),   .RVM, .ZO, .{AVX512F} ),
// VADDSD
    instr(.VADDSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x58),    .RVM, .ZO, .{AVX} ),
    instr(.VADDSD,     ops3(.xmm_kz, .xmm, .xmm_m64_er),           evex(.LIG,._F2,._0F,.W1,  0x58),    .RVM, .ZO, .{AVX512F} ),
// VADDSS
    instr(.VADDSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x58),    .RVM, .ZO, .{AVX} ),
    instr(.VADDSS,     ops3(.xmm_kz, .xmm, .xmm_m32_er),           evex(.LIG,._F3,._0F,.W0,  0x58),    .RVM, .ZO, .{AVX512F} ),
// VADDSUBPD
    instr(.VADDSUBPD,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0xD0),   .RVM, .ZO, .{AVX} ),
    instr(.VADDSUBPD,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0xD0),   .RVM, .ZO, .{AVX} ),
// VADDSUBPS
    instr(.VADDSUBPS,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._F2,._0F,.WIG, 0xD0),   .RVM, .ZO, .{AVX} ),
    instr(.VADDSUBPS,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._F2,._0F,.WIG, 0xD0),   .RVM, .ZO, .{AVX} ),
// VANDPD
    instr(.VANDPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x54),   .RVM, .ZO, .{AVX} ),
    instr(.VANDPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x54),   .RVM, .ZO, .{AVX} ),
    instr(.VANDPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x54),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x54),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x54),   .RVM, .ZO, .{AVX512DQ} ),
// VANDPS
    instr(.VANDPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x54),   .RVM, .ZO, .{AVX} ),
    instr(.VANDPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x54),   .RVM, .ZO, .{AVX} ),
    instr(.VANDPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x54),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x54),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x54),   .RVM, .ZO, .{AVX512DQ} ),
// VANDNPD
    instr(.VANDNPD,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x55),   .RVM, .ZO, .{AVX} ),
    instr(.VANDNPD,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x55),   .RVM, .ZO, .{AVX} ),
    instr(.VANDNPD,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x55),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDNPD,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x55),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDNPD,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x55),   .RVM, .ZO, .{AVX512DQ} ),
// VANDNPS
    instr(.VANDNPS,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x55),   .RVM, .ZO, .{AVX} ),
    instr(.VANDNPS,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x55),   .RVM, .ZO, .{AVX} ),
    instr(.VANDNPS,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x55),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDNPS,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x55),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VANDNPS,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x55),   .RVM, .ZO, .{AVX512DQ} ),
// VBLENDPS
    instr(.VBLENDPD,   ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F3A,.WIG,0x0D),  .RVMI,.ZO, .{AVX} ),
    instr(.VBLENDPD,   ops4(.ymml, .ymml, .ymml_m256, .imm8),       vex(.L256,._66,._0F3A,.WIG,0x0D),  .RVMI,.ZO, .{AVX} ),
// VBLENDPS
    instr(.VBLENDPS,   ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F3A,.WIG,0x0C),  .RVMI,.ZO, .{AVX} ),
    instr(.VBLENDPS,   ops4(.ymml, .ymml, .ymml_m256, .imm8),       vex(.L256,._66,._0F3A,.WIG,0x0C),  .RVMI,.ZO, .{AVX} ),
// VBLENDVPD
    instr(.VBLENDVPD,  ops4(.xmml, .xmml, .xmml_m128, .xmml),       vex(.L128,._66,._0F3A,.W0,0x4B),   .RVMR,.ZO, .{AVX} ),
    instr(.VBLENDVPD,  ops4(.ymml, .ymml, .ymml_m256, .ymml),       vex(.L256,._66,._0F3A,.W0,0x4B),   .RVMR,.ZO, .{AVX} ),
// VBLENDVPS
    instr(.VBLENDVPS,  ops4(.xmml, .xmml, .xmml_m128, .xmml),       vex(.L128,._66,._0F3A,.W0,0x4A),   .RVMR,.ZO, .{AVX} ),
    instr(.VBLENDVPS,  ops4(.ymml, .ymml, .ymml_m256, .ymml),       vex(.L256,._66,._0F3A,.W0,0x4A),   .RVMR,.ZO, .{AVX} ),
// VCMPPD
    instr(.VCMPPD,     ops4(.xmml, .xmml, .xmml_m128, .imm8),               vex(.L128,._66,._0F,.WIG, 0xC2),   .RVMI, .ZO, .{AVX} ),
    instr(.VCMPPD,     ops4(.ymml, .ymml, .ymml_m256, .imm8),               vex(.L256,._66,._0F,.WIG, 0xC2),   .RVMI, .ZO, .{AVX} ),
    instr(.VCMPPD,     ops4(.reg_k_k, .xmm, .xmm_m128_m64bcst, .imm8),     evex(.L128,._66,._0F,.W1,  0xC2),   .RVMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCMPPD,     ops4(.reg_k_k, .ymm, .ymm_m256_m64bcst, .imm8),     evex(.L256,._66,._0F,.W1,  0xC2),   .RVMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCMPPD,     ops4(.reg_k_k, .zmm, .zmm_m512_m64bcst_sae, .imm8), evex(.L512,._66,._0F,.W1,  0xC2),   .RVMI, .ZO, .{AVX512F} ),
// VCMPPS
    instr(.VCMPPS,     ops4(.xmml, .xmml, .xmml_m128, .imm8),               vex(.L128,._NP,._0F,.WIG, 0xC2),   .RVMI, .ZO, .{AVX} ),
    instr(.VCMPPS,     ops4(.ymml, .ymml, .ymml_m256, .imm8),               vex(.L256,._NP,._0F,.WIG, 0xC2),   .RVMI, .ZO, .{AVX} ),
    instr(.VCMPPS,     ops4(.reg_k_k, .xmm, .xmm_m128_m32bcst, .imm8),     evex(.L128,._NP,._0F,.W0,  0xC2),   .RVMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCMPPS,     ops4(.reg_k_k, .ymm, .ymm_m256_m32bcst, .imm8),     evex(.L256,._NP,._0F,.W0,  0xC2),   .RVMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCMPPS,     ops4(.reg_k_k, .zmm, .zmm_m512_m32bcst_sae, .imm8), evex(.L512,._NP,._0F,.W0,  0xC2),   .RVMI, .ZO, .{AVX512F} ),
// VCMPSD
    instr(.VCMPSD,     ops4(.xmml, .xmml, .xmml_m64, .imm8),                vex(.LIG,._F2,._0F,.WIG, 0xC2),    .RVMI, .ZO, .{AVX} ),
    instr(.VCMPSD,     ops4(.reg_k_k, .xmm, .xmm_m64_sae, .imm8),          evex(.LIG,._F2,._0F,.W1,  0xC2),    .RVMI, .ZO, .{AVX512VL, AVX512F} ),
// VCMPSS
    instr(.VCMPSS,     ops4(.xmml, .xmml, .xmml_m32, .imm8),                vex(.LIG,._F3,._0F,.WIG, 0xC2),    .RVMI, .ZO, .{AVX} ),
    instr(.VCMPSS,     ops4(.reg_k_k, .xmm, .xmm_m32_sae, .imm8),          evex(.LIG,._F3,._0F,.W0,  0xC2),    .RVMI, .ZO, .{AVX512VL, AVX512F} ),
// VCOMISD
    instr(.VCOMISD,    ops2(.xmml, .xmml_m64),                      vex(.LIG,._66,._0F,.WIG, 0x2F),    .vRM, .ZO,  .{AVX} ),
    instr(.VCOMISD,    ops2(.xmm, .xmm_m64_sae),                   evex(.LIG,._66,._0F,.W1,  0x2F),    .vRM, .ZO,  .{AVX512F} ),
// VCOMISS
    instr(.VCOMISS,    ops2(.xmml, .xmml_m32),                      vex(.LIG,._NP,._0F,.WIG, 0x2F),    .vRM, .ZO,  .{AVX} ),
    instr(.VCOMISS,    ops2(.xmm, .xmm_m32_sae),                   evex(.LIG,._NP,._0F,.W0,  0x2F),    .vRM, .ZO,  .{AVX512F} ),
// VCVTDQ2PD
    instr(.VCVTDQ2PD,  ops2(.xmml, .xmml_m64),                      vex(.L128,._F3,._0F,.WIG, 0xE6),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTDQ2PD,  ops2(.ymml, .xmml_m128),                     vex(.L256,._F3,._0F,.WIG, 0xE6),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTDQ2PD,  ops2(.xmm_kz, .xmm_m128_m32bcst),           evex(.L128,._F3,._0F,.W0,  0xE6),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTDQ2PD,  ops2(.ymm_kz, .xmm_m128_m32bcst),           evex(.L256,._F3,._0F,.W0,  0xE6),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTDQ2PD,  ops2(.zmm_kz, .ymm_m256_m32bcst),           evex(.L512,._F3,._0F,.W0,  0xE6),   .vRM, .ZO,  .{AVX512F} ),
// VCVTDQ2PS
    instr(.VCVTDQ2PS,  ops2(.xmml, .xmml_m128),                     vex(.L128,._NP,._0F,.WIG, 0x5B),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTDQ2PS,  ops2(.ymml, .ymml_m256),                     vex(.L256,._NP,._0F,.WIG, 0x5B),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTDQ2PS,  ops2(.xmm_kz, .xmm_m128_m32bcst),           evex(.L128,._NP,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTDQ2PS,  ops2(.ymm_kz, .ymm_m256_m32bcst),           evex(.L256,._NP,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTDQ2PS,  ops2(.zmm_kz, .zmm_m512_m32bcst_er),        evex(.L512,._NP,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512F} ),
// VCVTPD2DQ
    instr(.VCVTPD2DQ,  ops2(.xmml, .xmml_m128),                     vex(.L128,._F2,._0F,.WIG, 0xE6),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPD2DQ,  ops2(.xmml, .ymml_m256),                     vex(.L256,._F2,._0F,.WIG, 0xE6),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPD2DQ,  ops2(.xmm_kz, .xmm_m128_m64bcst),           evex(.L128,._F2,._0F,.W1,  0xE6),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2DQ,  ops2(.xmm_kz, .ymm_m256_m64bcst),           evex(.L256,._F2,._0F,.W1,  0xE6),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2DQ,  ops2(.ymm_kz, .zmm_m512_m64bcst_er),        evex(.L512,._F2,._0F,.W1,  0xE6),   .vRM, .ZO,  .{AVX512F} ),
// VCVTPD2PS
    instr(.VCVTPD2PS,  ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0x5A),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPD2PS,  ops2(.xmml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0x5A),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPD2PS,  ops2(.xmm_kz, .xmm_m128_m64bcst),           evex(.L128,._66,._0F,.W1,  0x5A),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2PS,  ops2(.xmm_kz, .ymm_m256_m64bcst),           evex(.L256,._66,._0F,.W1,  0x5A),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2PS,  ops2(.ymm_kz, .zmm_m512_m64bcst_er),        evex(.L512,._66,._0F,.W1,  0x5A),   .vRM, .ZO,  .{AVX512F} ),
// VCVTPS2DQ
    instr(.VCVTPS2DQ,  ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0x5B),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPS2DQ,  ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0x5B),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPS2DQ,  ops2(.xmm_kz, .xmm_m128_m32bcst),           evex(.L128,._66,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2DQ,  ops2(.ymm_kz, .ymm_m256_m32bcst),           evex(.L256,._66,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2DQ,  ops2(.zmm_kz, .zmm_m512_m32bcst_er),        evex(.L512,._66,._0F,.W0,  0x5B),   .vRM, .ZO,  .{AVX512F} ),
// VCVTPS2PD
    instr(.VCVTPS2PD,  ops2(.xmml, .xmml_m64),                      vex(.L128,._NP,._0F,.WIG, 0x5A),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPS2PD,  ops2(.ymml, .xmml_m128),                     vex(.L256,._NP,._0F,.WIG, 0x5A),   .vRM, .ZO,  .{AVX} ),
    instr(.VCVTPS2PD,  ops2(.xmm_kz, .xmm_m64_m32bcst),            evex(.L128,._NP,._0F,.W0,  0x5A),   .vRM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2PD,  ops2(.ymm_kz, .xmm_m128_m32bcst),           evex(.L256,._NP,._0F,.W0,  0x5A),   .vRM, .ZO,  .{AVX512VL} ),
    instr(.VCVTPS2PD,  ops2(.zmm_kz, .ymm_m256_m32bcst_sae),       evex(.L512,._NP,._0F,.W0,  0x5A),   .vRM, .ZO,  .{AVX512F} ),
// VCVTSD2SI
    instr(.VCVTSD2SI,  ops2(.reg32, .xmml_m64),                     vex(.LIG,._F2,._0F,.W0,  0x2D),    .vRM, .ZO, .{AVX} ),
    instr(.VCVTSD2SI,  ops2(.reg64, .xmml_m64),                     vex(.LIG,._F2,._0F,.W1,  0x2D),    .vRM, .ZO, .{AVX} ),
    instr(.VCVTSD2SI,  ops2(.reg32, .xmm_m64_er),                  evex(.LIG,._F2,._0F,.W0,  0x2D),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTSD2SI,  ops2(.reg64, .xmm_m64_er),                  evex(.LIG,._F2,._0F,.W1,  0x2D),    .vRM, .ZO, .{AVX512F} ),
// VCVTSD2SS
    instr(.VCVTSD2SS,  ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x5A),    .RVM, .ZO,  .{AVX} ),
    instr(.VCVTSD2SS,  ops3(.xmm_kz, .xmm, .xmm_m64_er),           evex(.LIG,._F2,._0F,.W1,  0x5A),    .RVM, .ZO,  .{AVX512F} ),
// VCVTSI2SD
    instr(.VCVTSI2SD,  ops3(.xmml, .xmml, .rm32),                   vex(.LIG,._F2,._0F,.W0,  0x2A),    .RVM, .ZO, .{AVX} ),
    instr(.VCVTSI2SD,  ops3(.xmml, .xmml, .rm64),                   vex(.LIG,._F2,._0F,.W1,  0x2A),    .RVM, .ZO, .{AVX, No32} ),
    instr(.VCVTSI2SD,  ops3(.xmm, .xmm, .rm32),                    evex(.LIG,._F2,._0F,.W0,  0x2A),    .RVM, .ZO, .{AVX512F} ),
    instr(.VCVTSI2SD,  ops3(.xmm, .xmm, .rm64_er),                 evex(.LIG,._F2,._0F,.W1,  0x2A),    .RVM, .ZO, .{AVX512F, No32} ),
// VCVTSI2SS
    instr(.VCVTSI2SS,  ops3(.xmml, .xmml, .rm32),                   vex(.LIG,._F3,._0F,.W0,  0x2A),    .RVM, .ZO, .{AVX} ),
    instr(.VCVTSI2SS,  ops3(.xmml, .xmml, .rm64),                   vex(.LIG,._F3,._0F,.W1,  0x2A),    .RVM, .ZO, .{AVX, No32} ),
    instr(.VCVTSI2SS,  ops3(.xmm, .xmm, .rm32_er),                 evex(.LIG,._F3,._0F,.W0,  0x2A),    .RVM, .ZO, .{AVX512F} ),
    instr(.VCVTSI2SS,  ops3(.xmm, .xmm, .rm64_er),                 evex(.LIG,._F3,._0F,.W1,  0x2A),    .RVM, .ZO, .{AVX512F, No32} ),
// VCVTSS2SD
    instr(.VCVTSS2SD,  ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x5A),    .RVM, .ZO,  .{AVX} ),
    instr(.VCVTSS2SD,  ops3(.xmm_kz, .xmm, .xmm_m32_sae),          evex(.LIG,._F3,._0F,.W0,  0x5A),    .RVM, .ZO,  .{AVX512F} ),
// VCVTSS2SI
    instr(.VCVTSS2SI,  ops2(.reg32, .xmml_m32),                     vex(.LIG,._F3,._0F,.W0,  0x2D),    .vRM, .ZO, .{AVX} ),
    instr(.VCVTSS2SI,  ops2(.reg64, .xmml_m32),                     vex(.LIG,._F3,._0F,.W1,  0x2D),    .vRM, .ZO, .{AVX, No32} ),
    instr(.VCVTSS2SI,  ops2(.reg32, .xmm_m32_er),                  evex(.LIG,._F3,._0F,.W0,  0x2D),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTSS2SI,  ops2(.reg64, .xmm_m32_er),                  evex(.LIG,._F3,._0F,.W1,  0x2D),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTTPD2DQ
    instr(.VCVTTPD2DQ, ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0xE6),   .vRM, .ZO, .{AVX} ),
    instr(.VCVTTPD2DQ, ops2(.xmml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0xE6),   .vRM, .ZO, .{AVX} ),
    instr(.VCVTTPD2DQ, ops2(.xmm_kz, .xmm_m128_m64bcst),           evex(.L128,._66,._0F,.W1,  0xE6),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPD2DQ, ops2(.xmm_kz, .ymm_m256_m64bcst),           evex(.L256,._66,._0F,.W1,  0xE6),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPD2DQ, ops2(.ymm_kz, .zmm_m512_m64bcst_sae),       evex(.L512,._66,._0F,.W1,  0xE6),   .vRM, .ZO, .{AVX512F} ),
// VCVTTPS2DQ
    instr(.VCVTTPS2DQ, ops2(.xmml, .xmml_m128),                     vex(.L128,._F3,._0F,.WIG, 0x5B),   .vRM, .ZO, .{AVX} ),
    instr(.VCVTTPS2DQ, ops2(.ymml, .ymml_m256),                     vex(.L256,._F3,._0F,.WIG, 0x5B),   .vRM, .ZO, .{AVX} ),
    instr(.VCVTTPS2DQ, ops2(.xmm_kz, .xmm_m128_m32bcst),           evex(.L128,._F3,._0F,.W0,  0x5B),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPS2DQ, ops2(.ymm_kz, .ymm_m256_m32bcst),           evex(.L256,._F3,._0F,.W0,  0x5B),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPS2DQ, ops2(.zmm_kz, .zmm_m512_m32bcst_sae),       evex(.L512,._F3,._0F,.W0,  0x5B),   .vRM, .ZO, .{AVX512F} ),
// VCVTTSD2SI
    instr(.VCVTTSD2SI, ops2(.reg32, .xmml_m64),                     vex(.LIG,._F2,._0F,.W0,  0x2C),    .vRM, .ZO, .{AVX} ),
    instr(.VCVTTSD2SI, ops2(.reg64, .xmml_m64),                     vex(.LIG,._F2,._0F,.W1,  0x2C),    .vRM, .ZO, .{AVX, No32} ),
    instr(.VCVTTSD2SI, ops2(.reg32, .xmm_m64_sae),                 evex(.LIG,._F2,._0F,.W0,  0x2C),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTTSD2SI, ops2(.reg64, .xmm_m64_sae),                 evex(.LIG,._F2,._0F,.W1,  0x2C),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTTSS2SI
    instr(.VCVTTSS2SI, ops2(.reg32, .xmml_m32),                     vex(.LIG,._F3,._0F,.W0,  0x2C),    .vRM, .ZO, .{AVX} ),
    instr(.VCVTTSS2SI, ops2(.reg64, .xmml_m32),                     vex(.LIG,._F3,._0F,.W1,  0x2C),    .vRM, .ZO, .{AVX, No32} ),
    instr(.VCVTTSS2SI, ops2(.reg32, .xmm_m32_sae),                 evex(.LIG,._F3,._0F,.W0,  0x2C),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTTSS2SI, ops2(.reg64, .xmm_m32_sae),                 evex(.LIG,._F3,._0F,.W1,  0x2C),    .vRM, .ZO, .{AVX512F, No32} ),
// VDIVPD
    instr(.VDIVPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x5E),   .RVM, .ZO, .{AVX} ),
    instr(.VDIVPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x5E),   .RVM, .ZO, .{AVX} ),
    instr(.VDIVPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x5E),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VDIVPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x5E),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VDIVPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_er),  evex(.L512,._66,._0F,.W1,  0x5E),   .RVM, .ZO, .{AVX512F} ),
// VDIVPS
    instr(.VDIVPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x5E),   .RVM, .ZO, .{AVX} ),
    instr(.VDIVPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x5E),   .RVM, .ZO, .{AVX} ),
    instr(.VDIVPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x5E),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VDIVPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x5E),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VDIVPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_er),  evex(.L512,._NP,._0F,.W0,  0x5E),   .RVM, .ZO, .{AVX512F} ),
// VDIVSD
    instr(.VDIVSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x5E),    .RVM, .ZO, .{AVX} ),
    instr(.VDIVSD,     ops3(.xmm_kz, .xmm, .xmm_m64_er),           evex(.LIG,._F2,._0F,.W1,  0x5E),    .RVM, .ZO, .{AVX512F} ),
// VDIVSS
    instr(.VDIVSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x5E),    .RVM, .ZO, .{AVX} ),
    instr(.VDIVSS,     ops3(.xmm_kz, .xmm, .xmm_m32_er),           evex(.LIG,._F3,._0F,.W0,  0x5E),    .RVM, .ZO, .{AVX512F} ),
// VDPPD
    instr(.VDPPD,      ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F3A,.WIG, 0x41), .RVMI,.ZO, .{AVX} ),
// VDPPS
    instr(.VDPPS,      ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F3A,.WIG, 0x40), .RVMI,.ZO, .{AVX} ),
    instr(.VDPPS,      ops4(.ymml, .ymml, .ymml_m256, .imm8),       vex(.L256,._66,._0F3A,.WIG, 0x40), .RVMI,.ZO, .{AVX} ),
// VEXTRACTPS
    instr(.VEXTRACTPS, ops3(.rm32, .xmml, .imm8),                   vex(.L128,._66,._0F3A,.WIG, 0x17), .vMRI,.ZO, .{AVX} ),
    instr(.VEXTRACTPS, ops3(.reg64, .xmml, .imm8),                  vex(.L128,._66,._0F3A,.WIG, 0x17), .vMRI,.ZO, .{AVX, No32} ),
    instr(.VEXTRACTPS, ops3(.rm32, .xmm, .imm8),                   evex(.L128,._66,._0F3A,.WIG, 0x17), .vMRI,.ZO, .{AVX512F} ),
    instr(.VEXTRACTPS, ops3(.reg64, .xmm, .imm8),                  evex(.L128,._66,._0F3A,.WIG, 0x17), .vMRI,.ZO, .{AVX512F, No32} ),
// VGF2P8AFFINEINVQB
    instr(.VGF2P8AFFINEINVQB, ops4(.xmml,.xmml,.xmml_m128,.imm8),           vex(.L128,._66,._0F3A,.W1, 0xCF),  .RVMI,.ZO, .{AVX, GFNI} ),
    instr(.VGF2P8AFFINEINVQB, ops4(.ymml,.ymml,.ymml_m256,.imm8),           vex(.L256,._66,._0F3A,.W1, 0xCF),  .RVMI,.ZO, .{AVX, GFNI} ),
    instr(.VGF2P8AFFINEINVQB, ops4(.xmm_kz,.xmm,.xmm_m128_m64bcst,.imm8),  evex(.L128,._66,._0F3A,.W1, 0xCF),  .RVMI,.ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8AFFINEINVQB, ops4(.ymm_kz,.ymm,.ymm_m256_m64bcst,.imm8),  evex(.L256,._66,._0F3A,.W1, 0xCF),  .RVMI,.ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8AFFINEINVQB, ops4(.zmm_kz,.zmm,.zmm_m512_m64bcst,.imm8),  evex(.L512,._66,._0F3A,.W1, 0xCF),  .RVMI,.ZO, .{AVX512F, GFNI} ),
// VGF2P8AFFINEQB
    instr(.VGF2P8AFFINEQB,    ops4(.xmml,.xmml,.xmml_m128,.imm8),           vex(.L128,._66,._0F3A,.W1, 0xCE),  .RVMI,.ZO, .{AVX, GFNI} ),
    instr(.VGF2P8AFFINEQB,    ops4(.ymml,.ymml,.ymml_m256,.imm8),           vex(.L256,._66,._0F3A,.W1, 0xCE),  .RVMI,.ZO, .{AVX, GFNI} ),
    instr(.VGF2P8AFFINEQB,    ops4(.xmm_kz,.xmm,.xmm_m128_m64bcst,.imm8),  evex(.L128,._66,._0F3A,.W1, 0xCE),  .RVMI,.ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8AFFINEQB,    ops4(.ymm_kz,.ymm,.ymm_m256_m64bcst,.imm8),  evex(.L256,._66,._0F3A,.W1, 0xCE),  .RVMI,.ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8AFFINEQB,    ops4(.zmm_kz,.zmm,.zmm_m512_m64bcst,.imm8),  evex(.L512,._66,._0F3A,.W1, 0xCE),  .RVMI,.ZO, .{AVX512F, GFNI} ),
// VGF2P8MULB
    instr(.VGF2P8MULB,        ops3(.xmml, .xmml, .xmml_m128),               vex(.L128,._66,._0F38,.W0, 0xCF),  .RVM, .ZO, .{AVX, GFNI} ),
    instr(.VGF2P8MULB,        ops3(.ymml, .ymml, .ymml_m256),               vex(.L256,._66,._0F38,.W0, 0xCF),  .RVM, .ZO, .{AVX, GFNI} ),
    instr(.VGF2P8MULB,        ops3(.xmm_kz, .xmm, .xmm_m128),              evex(.L128,._66,._0F38,.W0, 0xCF),  .RVM, .ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8MULB,        ops3(.ymm_kz, .ymm, .ymm_m256),              evex(.L256,._66,._0F38,.W0, 0xCF),  .RVM, .ZO, .{AVX512VL, GFNI} ),
    instr(.VGF2P8MULB,        ops3(.zmm_kz, .zmm, .zmm_m512),              evex(.L512,._66,._0F38,.W0, 0xCF),  .RVM, .ZO, .{AVX512F, GFNI} ),
// VHADDPD
    instr(.VHADDPD,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x7C),    .RVM, .ZO, .{AVX} ),
    instr(.VHADDPD,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x7C),    .RVM, .ZO, .{AVX} ),
// VHADDPS
    instr(.VHADDPS,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._F2,._0F,.WIG, 0x7C),    .RVM, .ZO, .{AVX} ),
    instr(.VHADDPS,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._F2,._0F,.WIG, 0x7C),    .RVM, .ZO, .{AVX} ),
// VHSUBPD
    instr(.VHSUBPD,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x7D),    .RVM, .ZO, .{AVX} ),
    instr(.VHSUBPD,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x7D),    .RVM, .ZO, .{AVX} ),
// VHSUBPS
    instr(.VHSUBPS,    ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._F2,._0F,.WIG, 0x7D),    .RVM, .ZO, .{AVX} ),
    instr(.VHSUBPS,    ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._F2,._0F,.WIG, 0x7D),    .RVM, .ZO, .{AVX} ),
// VINSERTPS
    instr(.VINSERTPS,  ops4(.xmml, .xmml, .xmml_m32, .imm8),        vex(.L128,._66,._0F3A,.WIG, 0x21),  .RVMI,.ZO, .{AVX} ),
    instr(.VINSERTPS,  ops4(.xmm, .xmm, .xmm_m32, .imm8),          evex(.L128,._66,._0F3A,.W0,  0x21),  .RVMI,.ZO, .{AVX512F} ),
// LDDQU
    instr(.VLDDQU,     ops2(.xmml, .rm_mem128),                     vex(.L128,._F2,._0F,.WIG, 0xF0),    .vRM, .ZO, .{AVX} ),
    instr(.VLDDQU,     ops2(.ymml, .rm_mem256),                     vex(.L256,._F2,._0F,.WIG, 0xF0),    .vRM, .ZO, .{AVX} ),
// VLDMXCSR
    instr(.VLDMXCSR,   ops1(.rm_mem32),                             vexr(.LZ,._NP,._0F,.WIG, 0xAE, 2),  .vM,  .ZO, .{AVX} ),
// VMASKMOVDQU
    instr(.VMASKMOVDQU,ops2(.xmml, .xmml),                          vex(.L128,._66,._0F,.WIG, 0xF7),    .vRM, .ZO, .{AVX} ),
// VMAXPD
    instr(.VMAXPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x5F),    .RVM, .ZO, .{AVX} ),
    instr(.VMAXPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x5F),    .RVM, .ZO, .{AVX} ),
    instr(.VMAXPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x5F),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMAXPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x5F),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMAXPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_sae), evex(.L512,._66,._0F,.W1,  0x5F),    .RVM, .ZO, .{AVX512DQ} ),
// VMAXPS
    instr(.VMAXPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x5F),    .RVM, .ZO, .{AVX} ),
    instr(.VMAXPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x5F),    .RVM, .ZO, .{AVX} ),
    instr(.VMAXPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x5F),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMAXPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x5F),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMAXPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_sae), evex(.L512,._NP,._0F,.W0,  0x5F),    .RVM, .ZO, .{AVX512DQ} ),
// VMAXSD
    instr(.VMAXSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x5F),     .RVM, .ZO, .{AVX} ),
    instr(.VMAXSD,     ops3(.xmm_kz, .xmm, .xmm_m64_sae),          evex(.LIG,._F2,._0F,.W1,  0x5F),     .RVM, .ZO, .{AVX512F} ),
// VMAXSS
    instr(.VMAXSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x5F),     .RVM, .ZO, .{AVX} ),
    instr(.VMAXSS,     ops3(.xmm_kz, .xmm, .xmm_m32_sae),          evex(.LIG,._F3,._0F,.W0,  0x5F),     .RVM, .ZO, .{AVX512F} ),
// VMINPD
    instr(.VMINPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x5D),    .RVM, .ZO, .{AVX} ),
    instr(.VMINPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x5D),    .RVM, .ZO, .{AVX} ),
    instr(.VMINPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x5D),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMINPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x5D),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMINPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_sae), evex(.L512,._66,._0F,.W1,  0x5D),    .RVM, .ZO, .{AVX512DQ} ),
// VMINPS
    instr(.VMINPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x5D),    .RVM, .ZO, .{AVX} ),
    instr(.VMINPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x5D),    .RVM, .ZO, .{AVX} ),
    instr(.VMINPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x5D),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMINPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x5D),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VMINPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_sae), evex(.L512,._NP,._0F,.W0,  0x5D),    .RVM, .ZO, .{AVX512DQ} ),
// VMINSD
    instr(.VMINSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x5D),     .RVM, .ZO, .{AVX} ),
    instr(.VMINSD,     ops3(.xmm_kz, .xmm, .xmm_m64_sae),          evex(.LIG,._F2,._0F,.W1,  0x5D),     .RVM, .ZO, .{AVX512F} ),
// VMINSS
    instr(.VMINSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x5D),     .RVM, .ZO, .{AVX} ),
    instr(.VMINSS,     ops3(.xmm_kz, .xmm, .xmm_m32_sae),          evex(.LIG,._F3,._0F,.W0,  0x5D),     .RVM, .ZO, .{AVX512F} ),
// VMOVAPD
    instr(.VMOVAPD,    ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0x28),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVAPD,    ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0x28),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVAPD,    ops2(.xmml_m128, .xmml),                     vex(.L128,._66,._0F,.WIG, 0x29),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVAPD,    ops2(.ymml_m256, .ymml),                     vex(.L256,._66,._0F,.WIG, 0x29),    .vMR, .ZO, .{AVX} ),
    //
    instr(.VMOVAPD,    ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F,.W1,  0x28),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPD,    ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F,.W1,  0x28),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPD,    ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F,.W1,  0x28),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVAPD,    ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._66,._0F,.W1,  0x29),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPD,    ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._66,._0F,.W1,  0x29),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPD,    ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._66,._0F,.W1,  0x29),    .vMR, .ZO, .{AVX512F} ),
// VMOVAPS
    instr(.VMOVAPS,    ops2(.xmml, .xmml_m128),                     vex(.L128,._NP,._0F,.WIG, 0x28),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVAPS,    ops2(.ymml, .ymml_m256),                     vex(.L256,._NP,._0F,.WIG, 0x28),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVAPS,    ops2(.xmml_m128, .xmml),                     vex(.L128,._NP,._0F,.WIG, 0x29),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVAPS,    ops2(.ymml_m256, .ymml),                     vex(.L256,._NP,._0F,.WIG, 0x29),    .vMR, .ZO, .{AVX} ),
    //
    instr(.VMOVAPS,    ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._NP,._0F,.W0,  0x28),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPS,    ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._NP,._0F,.W0,  0x28),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPS,    ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._NP,._0F,.W0,  0x28),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVAPS,    ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._NP,._0F,.W0,  0x29),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPS,    ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._NP,._0F,.W0,  0x29),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVAPS,    ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._NP,._0F,.W0,  0x29),    .vMR, .ZO, .{AVX512F} ),
// VMOVD
    // xmm[0..15]
    instr(.VMOVD,      ops2(.xmml, .rm32),                          vex(.L128,._66,._0F,.W0, 0x6E),     .vRM, .RM32, .{AVX} ),
    instr(.VMOVD,      ops2(.rm32, .xmml),                          vex(.L128,._66,._0F,.W0, 0x7E),     .vMR, .RM32, .{AVX} ),
    instr(.VMOVD,      ops2(.xmml, .rm64),                          vex(.L128,._66,._0F,.W1, 0x6E),     .vRM, .RM32, .{AVX} ),
    instr(.VMOVD,      ops2(.rm64, .xmml),                          vex(.L128,._66,._0F,.W1, 0x7E),     .vMR, .RM32, .{AVX} ),
    // xmm[0..31]
    instr(.VMOVD,      ops2(.xmm, .rm32),                          evex(.L128,._66,._0F,.W0, 0x6E),     .vRM, .RM32, .{AVX512F} ),
    instr(.VMOVD,      ops2(.rm32, .xmm),                          evex(.L128,._66,._0F,.W0, 0x7E),     .vMR, .RM32, .{AVX512F} ),
    instr(.VMOVD,      ops2(.xmm, .rm64),                          evex(.L128,._66,._0F,.W1, 0x6E),     .vRM, .RM32, .{AVX512F} ),
    instr(.VMOVD,      ops2(.rm64, .xmm),                          evex(.L128,._66,._0F,.W1, 0x7E),     .vMR, .RM32, .{AVX512F} ),
// VMOVQ
    // xmm[0..15]
    instr(.VMOVQ,      ops2(.xmml, .xmml_m64),                      vex(.L128,._F3,._0F,.WIG,0x7E),     .vRM, .ZO,   .{AVX} ),
    instr(.VMOVQ,      ops2(.xmml_m64, .xmml),                      vex(.L128,._66,._0F,.WIG,0xD6),     .vMR, .ZO,   .{AVX} ),
    instr(.VMOVQ,      ops2(.xmml, .rm64),                          vex(.L128,._66,._0F,.W1, 0x6E),     .vRM, .RM32, .{AVX} ),
    instr(.VMOVQ,      ops2(.rm64, .xmml),                          vex(.L128,._66,._0F,.W1, 0x7E),     .vMR, .RM32, .{AVX} ),
    // xmm[0..31]
    instr(.VMOVQ,      ops2(.xmm, .xmm_m64),                       evex(.L128,._F3,._0F,.W1, 0x7E),     .vRM, .ZO,   .{AVX512F} ),
    instr(.VMOVQ,      ops2(.xmm_m64, .xmm),                       evex(.L128,._66,._0F,.W1, 0xD6),     .vMR, .ZO,   .{AVX512F} ),
    instr(.VMOVQ,      ops2(.xmm, .rm64),                          evex(.L128,._66,._0F,.W1, 0x6E),     .vRM, .RM32, .{AVX512F} ),
    instr(.VMOVQ,      ops2(.rm64, .xmm),                          evex(.L128,._66,._0F,.W1, 0x7E),     .vMR, .RM32, .{AVX512F} ),
// VMOVDDUP
    instr(.VMOVDDUP,   ops2(.xmml, .xmml_m64),                      vex(.L128,._F2,._0F,.WIG, 0x12),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDDUP,   ops2(.ymml, .ymml_m256),                     vex(.L256,._F2,._0F,.WIG, 0x12),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDDUP,   ops2(.xmm_kz, .xmm_m64),                    evex(.L128,._F2,._0F,.W1,  0x12),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDDUP,   ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F2,._0F,.W1,  0x12),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDDUP,   ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F2,._0F,.W1,  0x12),    .vRM, .ZO, .{AVX512F} ),
// VMOVDQA / VMOVDQA32 / VMOVDQA64
    instr(.VMOVDQA,    ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0x6F),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDQA,    ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0x6F),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDQA,    ops2(.xmml_m128, .xmml),                     vex(.L128,._66,._0F,.WIG, 0x7F),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVDQA,    ops2(.ymml_m256, .ymml),                     vex(.L256,._66,._0F,.WIG, 0x7F),    .vMR, .ZO, .{AVX} ),
    // VMOVDQA32
    instr(.VMOVDQA32,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA32,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA32,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVDQA32,  ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._66,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA32,  ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._66,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA32,  ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._66,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512F} ),
    // VMOVDQA64
    instr(.VMOVDQA64,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA64,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA64,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVDQA64,  ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._66,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA64,  ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._66,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQA64,  ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._66,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512F} ),
// VMOVDQU / VMOVDQU8 / VMOVDQU16 / VMOVDQU32 / VMOVDQU64
    instr(.VMOVDQU,    ops2(.xmml, .xmml_m128),                     vex(.L128,._F3,._0F,.WIG, 0x6F),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDQU,    ops2(.ymml, .ymml_m256),                     vex(.L256,._F3,._0F,.WIG, 0x6F),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVDQU,    ops2(.xmml_m128, .xmml),                     vex(.L128,._F3,._0F,.WIG, 0x7F),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVDQU,    ops2(.ymml_m256, .ymml),                     vex(.L256,._F3,._0F,.WIG, 0x7F),    .vMR, .ZO, .{AVX} ),
    // VMOVDQU8
    instr(.VMOVDQU8,  ops2(.xmm_kz, .xmm_m128),                    evex(.L128,._F2,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU8,  ops2(.ymm_kz, .ymm_m256),                    evex(.L256,._F2,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU8,  ops2(.zmm_kz, .zmm_m512),                    evex(.L512,._F2,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512BW} ),
    instr(.VMOVDQU8,  ops2(.xmm_m128_kz, .xmm),                    evex(.L128,._F2,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU8,  ops2(.ymm_m256_kz, .ymm),                    evex(.L256,._F2,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU8,  ops2(.zmm_m512_kz, .zmm),                    evex(.L512,._F2,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512BW} ),
    // VMOVDQU16
    instr(.VMOVDQU16,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._F2,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU16,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F2,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU16,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F2,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512BW} ),
    instr(.VMOVDQU16,  ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._F2,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU16,  ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._F2,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VMOVDQU16,  ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._F2,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512BW} ),
    // VMOVDQU32
    instr(.VMOVDQU32,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._F3,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU32,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F3,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU32,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F3,._0F,.W0,  0x6F),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVDQU32,  ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._F3,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU32,  ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._F3,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU32,  ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._F3,._0F,.W0,  0x7F),    .vMR, .ZO, .{AVX512F} ),
    // VMOVDQU64
    instr(.VMOVDQU64,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._F3,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU64,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F3,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU64,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F3,._0F,.W1,  0x6F),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVDQU64,  ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._F3,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU64,  ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._F3,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVDQU64,  ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._F3,._0F,.W1,  0x7F),    .vMR, .ZO, .{AVX512F} ),
// VMOVHLPS
    instr(.VMOVHLPS,   ops3(.xmml, .xmml, .xmml),                   vex(.L128,._NP,._0F,.WIG, 0x12),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVHLPS,   ops3(.xmm, .xmm, .xmm),                     evex(.L128,._NP,._0F,.W0,  0x12),    .RVM, .ZO, .{AVX512F} ),
// VMOVHPD
    instr(.VMOVHPD,    ops3(.xmml, .xmml, .rm_mem64),               vex(.L128,._66,._0F,.WIG, 0x16),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVHPD,    ops2(.rm_mem64, .xmml),                      vex(.L128,._66,._0F,.WIG, 0x17),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVHPD,    ops3(.xmm, .xmm, .rm_mem64),                evex(.L128,._66,._0F,.W1,  0x16),    .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVHPD,    ops2(.rm_mem64, .xmm),                      evex(.L128,._66,._0F,.W1,  0x17),    .vMR, .ZO, .{AVX512F} ),
// VMOVHPS
    instr(.VMOVHPS,    ops3(.xmml, .xmml, .rm_mem64),               vex(.L128,._NP,._0F,.WIG, 0x16),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVHPS,    ops2(.rm_mem64, .xmml),                      vex(.L128,._NP,._0F,.WIG, 0x17),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVHPS,    ops3(.xmm, .xmm, .rm_mem64),                evex(.L128,._NP,._0F,.W0,  0x16),    .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVHPS,    ops2(.rm_mem64, .xmm),                      evex(.L128,._NP,._0F,.W0,  0x17),    .vMR, .ZO, .{AVX512F} ),
// VMOVLHPS
    instr(.VMOVLHPS,   ops3(.xmml, .xmml, .xmml),                   vex(.L128,._NP,._0F,.WIG, 0x16),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVLHPS,   ops3(.xmm, .xmm, .xmm),                     evex(.L128,._NP,._0F,.W0,  0x16),    .RVM, .ZO, .{AVX512F} ),
// VMOVLPD
    instr(.VMOVLPD,    ops3(.xmml, .xmml, .rm_mem64),               vex(.L128,._66,._0F,.WIG, 0x12),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVLPD,    ops2(.rm_mem64, .xmml),                      vex(.L128,._66,._0F,.WIG, 0x13),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVLPD,    ops3(.xmm, .xmm, .rm_mem64),                evex(.L128,._66,._0F,.W1,  0x12),    .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVLPD,    ops2(.rm_mem64, .xmm),                      evex(.L128,._66,._0F,.W1,  0x13),    .vMR, .ZO, .{AVX512F} ),
// VMOVLPS
    instr(.VMOVLPS,    ops3(.xmml, .xmml, .rm_mem64),               vex(.L128,._NP,._0F,.WIG, 0x12),    .RVM, .ZO, .{AVX} ),
    instr(.VMOVLPS,    ops2(.rm_mem64, .xmml),                      vex(.L128,._NP,._0F,.WIG, 0x13),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVLPS,    ops3(.xmm, .xmm, .rm_mem64),                evex(.L128,._NP,._0F,.W0,  0x12),    .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVLPS,    ops2(.rm_mem64, .xmm),                      evex(.L128,._NP,._0F,.W0,  0x13),    .vMR, .ZO, .{AVX512F} ),
// VMOVMSKPD
    instr(.VMOVMSKPD,  ops2(.reg32, .xmml),                         vex(.L128,._66,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPD,  ops2(.reg64, .xmml),                         vex(.L128,._66,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPD,  ops2(.reg32, .ymml),                         vex(.L256,._66,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPD,  ops2(.reg64, .ymml),                         vex(.L256,._66,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
// VMOVMSKPS
    instr(.VMOVMSKPS,  ops2(.reg32, .xmml),                         vex(.L128,._NP,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPS,  ops2(.reg64, .xmml),                         vex(.L128,._NP,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPS,  ops2(.reg32, .ymml),                         vex(.L256,._NP,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVMSKPS,  ops2(.reg64, .ymml),                         vex(.L256,._NP,._0F,.WIG, 0x50),    .vRM, .ZO, .{AVX} ),
// VMOVNTDQA
    instr(.VMOVNTDQA,  ops2(.xmml, .rm_mem128),                     vex(.L128,._66,._0F38,.WIG, 0x2A),  .vRM, .ZO, .{AVX} ),
    instr(.VMOVNTDQA,  ops2(.ymml, .rm_mem256),                     vex(.L256,._66,._0F38,.WIG, 0x2A),  .vRM, .ZO, .{AVX2} ),
    instr(.VMOVNTDQA,  ops2(.xmm, .rm_mem128),                     evex(.L128,._66,._0F38,.W0,  0x2A),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTDQA,  ops2(.ymm, .rm_mem256),                     evex(.L256,._66,._0F38,.W0,  0x2A),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTDQA,  ops2(.zmm, .rm_mem512),                     evex(.L512,._66,._0F38,.W0,  0x2A),  .vRM, .ZO, .{AVX512F} ),
// VMOVNTDQ
    instr(.VMOVNTDQ,   ops2(.rm_mem128, .xmml),                     vex(.L128,._66,._0F,.WIG, 0xE7),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTDQ,   ops2(.rm_mem256, .ymml),                     vex(.L256,._66,._0F,.WIG, 0xE7),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTDQ,   ops2(.rm_mem128, .xmm),                     evex(.L128,._66,._0F,.W0,  0xE7),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTDQ,   ops2(.rm_mem256, .ymm),                     evex(.L256,._66,._0F,.W0,  0xE7),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTDQ,   ops2(.rm_mem512, .zmm),                     evex(.L512,._66,._0F,.W0,  0xE7),    .vMR, .ZO, .{AVX512F} ),
// VMOVNTPD
    instr(.VMOVNTPD,   ops2(.rm_mem128, .xmml),                     vex(.L128,._66,._0F,.WIG, 0x2B),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTPD,   ops2(.rm_mem256, .ymml),                     vex(.L256,._66,._0F,.WIG, 0x2B),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTPD,   ops2(.rm_mem128, .xmm),                     evex(.L128,._66,._0F,.W1,  0x2B),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTPD,   ops2(.rm_mem256, .ymm),                     evex(.L256,._66,._0F,.W1,  0x2B),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTPD,   ops2(.rm_mem512, .zmm),                     evex(.L512,._66,._0F,.W1,  0x2B),    .vMR, .ZO, .{AVX512F} ),
// VMOVNTPS
    instr(.VMOVNTPS,   ops2(.rm_mem128, .xmml),                     vex(.L128,._NP,._0F,.WIG, 0x2B),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTPS,   ops2(.rm_mem256, .ymml),                     vex(.L256,._NP,._0F,.WIG, 0x2B),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVNTPS,   ops2(.rm_mem128, .xmm),                     evex(.L128,._NP,._0F,.W0,  0x2B),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTPS,   ops2(.rm_mem256, .ymm),                     evex(.L256,._NP,._0F,.W0,  0x2B),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVNTPS,   ops2(.rm_mem512, .zmm),                     evex(.L512,._NP,._0F,.W0,  0x2B),    .vMR, .ZO, .{AVX512F} ),
// VMOVSD
    instr(.VMOVSD,     ops3(.xmml, .xmml, .rm_xmml),                vex(.LIG,._F2,._0F,.WIG, 0x10),     .RVM, .ZO, .{AVX} ),
    instr(.VMOVSD,     ops2(.xmml, .rm_mem64),                      vex(.LIG,._F2,._0F,.WIG, 0x10),     .vRM, .ZO, .{AVX} ),
    instr(.VMOVSD,     ops3(.rm_xmml, .xmml, .xmml),                vex(.LIG,._F2,._0F,.WIG, 0x11),     .MVR, .ZO, .{AVX} ),
    instr(.VMOVSD,     ops2(.rm_mem64, .xmml),                      vex(.LIG,._F2,._0F,.WIG, 0x11),     .vMR, .ZO, .{AVX} ),
    instr(.VMOVSD,     ops3(.xmm_kz, .xmm, .rm_xmm),               evex(.LIG,._F2,._0F,.W1,  0x10),     .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVSD,     ops2(.xmm_kz, .rm_mem64),                   evex(.LIG,._F2,._0F,.W1,  0x10),     .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVSD,     ops3(.rm_xmm_kz, .xmm, .xmm),               evex(.LIG,._F2,._0F,.W1,  0x11),     .MVR, .ZO, .{AVX512F} ),
    instr(.VMOVSD,     ops2(.rm_mem64_kz, .xmm),                   evex(.LIG,._F2,._0F,.W1,  0x11),     .vMR, .ZO, .{AVX512F} ),
// VMOVSHDUP
    instr(.VMOVSHDUP,  ops2(.xmml, .xmml_m128),                     vex(.L128,._F3,._0F,.WIG, 0x16),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVSHDUP,  ops2(.ymml, .ymml_m256),                     vex(.L256,._F3,._0F,.WIG, 0x16),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVSHDUP,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._F3,._0F,.W0,  0x16),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVSHDUP,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F3,._0F,.W0,  0x16),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVSHDUP,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F3,._0F,.W0,  0x16),    .vRM, .ZO, .{AVX512F} ),
// VMOVSLDUP
    instr(.VMOVSLDUP,  ops2(.xmml, .xmml_m128),                     vex(.L128,._F3,._0F,.WIG, 0x12),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVSLDUP,  ops2(.ymml, .ymml_m256),                     vex(.L256,._F3,._0F,.WIG, 0x12),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVSLDUP,  ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._F3,._0F,.W0,  0x12),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVSLDUP,  ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._F3,._0F,.W0,  0x12),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVSLDUP,  ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._F3,._0F,.W0,  0x12),    .vRM, .ZO, .{AVX512F} ),
// VMOVSS
    instr(.VMOVSS,     ops3(.xmml, .xmml, .rm_xmml),                vex(.LIG,._F3,._0F,.WIG, 0x10),     .RVM, .ZO, .{AVX} ),
    instr(.VMOVSS,     ops2(.xmml, .rm_mem64),                      vex(.LIG,._F3,._0F,.WIG, 0x10),     .vRM, .ZO, .{AVX} ),
    instr(.VMOVSS,     ops3(.rm_xmml, .xmml, .xmml),                vex(.LIG,._F3,._0F,.WIG, 0x11),     .MVR, .ZO, .{AVX} ),
    instr(.VMOVSS,     ops2(.rm_mem64, .xmml),                      vex(.LIG,._F3,._0F,.WIG, 0x11),     .vMR, .ZO, .{AVX} ),
    instr(.VMOVSS,     ops3(.xmm_kz, .xmm, .xmm),                  evex(.LIG,._F3,._0F,.W0,  0x10),     .RVM, .ZO, .{AVX512F} ),
    instr(.VMOVSS,     ops2(.xmm_kz, .rm_mem64),                   evex(.LIG,._F3,._0F,.W0,  0x10),     .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVSS,     ops3(.rm_xmm_kz, .xmm, .xmm),               evex(.LIG,._F3,._0F,.W0,  0x11),     .MVR, .ZO, .{AVX512F} ),
    instr(.VMOVSS,     ops2(.rm_mem64_kz, .xmm),                   evex(.LIG,._F3,._0F,.W0,  0x11),     .vMR, .ZO, .{AVX512F} ),
// VMOVUPD
    instr(.VMOVUPD,    ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F,.WIG, 0x10),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVUPD,    ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F,.WIG, 0x10),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVUPD,    ops2(.xmml_m128, .xmml),                     vex(.L128,._66,._0F,.WIG, 0x11),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVUPD,    ops2(.ymml_m256, .ymml),                     vex(.L256,._66,._0F,.WIG, 0x11),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVUPD,    ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F,.W1,  0x10),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPD,    ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F,.W1,  0x10),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPD,    ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F,.W1,  0x10),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVUPD,    ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._66,._0F,.W1,  0x11),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPD,    ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._66,._0F,.W1,  0x11),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPD,    ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._66,._0F,.W1,  0x11),    .vMR, .ZO, .{AVX512F} ),
// VMOVUPS
    instr(.VMOVUPS,    ops2(.xmml, .xmml_m128),                     vex(.L128,._NP,._0F,.WIG, 0x10),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVUPS,    ops2(.ymml, .ymml_m256),                     vex(.L256,._NP,._0F,.WIG, 0x10),    .vRM, .ZO, .{AVX} ),
    instr(.VMOVUPS,    ops2(.xmml_m128, .xmml),                     vex(.L128,._NP,._0F,.WIG, 0x11),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVUPS,    ops2(.ymml_m256, .ymml),                     vex(.L256,._NP,._0F,.WIG, 0x11),    .vMR, .ZO, .{AVX} ),
    instr(.VMOVUPS,    ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._NP,._0F,.W0,  0x10),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPS,    ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._NP,._0F,.W0,  0x10),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPS,    ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._NP,._0F,.W0,  0x10),    .vRM, .ZO, .{AVX512F} ),
    instr(.VMOVUPS,    ops2(.xmm_m128_kz, .xmm),                   evex(.L128,._NP,._0F,.W0,  0x11),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPS,    ops2(.ymm_m256_kz, .ymm),                   evex(.L256,._NP,._0F,.W0,  0x11),    .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMOVUPS,    ops2(.zmm_m512_kz, .zmm),                   evex(.L512,._NP,._0F,.W0,  0x11),    .vMR, .ZO, .{AVX512F} ),
// VMPSADBW
    instr(.VMPSADBW,   ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F3A,.WIG, 0x42),  .RVMI,.ZO, .{AVX} ),
    instr(.VMPSADBW,   ops4(.ymml, .ymml, .ymml_m256, .imm8),       vex(.L256,._66,._0F3A,.WIG, 0x42),  .RVMI,.ZO, .{AVX2} ),
// VMULPD
    instr(.VMULPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x59),    .RVM, .ZO, .{AVX} ),
    instr(.VMULPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x59),    .RVM, .ZO, .{AVX} ),
    instr(.VMULPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x59),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMULPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x59),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMULPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_er),  evex(.L512,._66,._0F,.W1,  0x59),    .RVM, .ZO, .{AVX512F} ),
// VMULPS
    instr(.VMULPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x59),    .RVM, .ZO, .{AVX} ),
    instr(.VMULPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x59),    .RVM, .ZO, .{AVX} ),
    instr(.VMULPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x59),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMULPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x59),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VMULPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_er),  evex(.L512,._NP,._0F,.W0,  0x59),    .RVM, .ZO, .{AVX512F} ),
// VMULSD
    instr(.VMULSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x59),     .RVM, .ZO, .{AVX} ),
    instr(.VMULSD,     ops3(.xmm_kz, .xmm, .xmm_m64_er),           evex(.LIG,._F2,._0F,.W1,  0x59),     .RVM, .ZO, .{AVX512F} ),
// VMULSS
    instr(.VMULSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x59),     .RVM, .ZO, .{AVX} ),
    instr(.VMULSS,     ops3(.xmm_kz, .xmm, .xmm_m32_er),           evex(.LIG,._F3,._0F,.W0,  0x59),     .RVM, .ZO, .{AVX512F} ),
// VORPD
    instr(.VORPD,      ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x56),    .RVM, .ZO, .{AVX} ),
    instr(.VORPD,      ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x56),    .RVM, .ZO, .{AVX} ),
    instr(.VORPD,      ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x56),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VORPD,      ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x56),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VORPD,      ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x56),    .RVM, .ZO, .{AVX512DQ} ),
// VORPS
    instr(.VORPS,      ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x56),    .RVM, .ZO, .{AVX} ),
    instr(.VORPS,      ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x56),    .RVM, .ZO, .{AVX} ),
    instr(.VORPS,      ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x56),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VORPS,      ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x56),    .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VORPS,      ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x56),    .RVM, .ZO, .{AVX512DQ} ),
// VPABSB / VPABSW / VPABSD / VPABSQ
    instr(.VPABSB,     ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F38,.WIG, 0x1C),  .vRM, .ZO, .{AVX} ),
    instr(.VPABSB,     ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F38,.WIG, 0x1C),  .vRM, .ZO, .{AVX2} ),
    instr(.VPABSB,     ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F38,.WIG, 0x1C),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPABSB,     ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F38,.WIG, 0x1C),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPABSB,     ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F38,.WIG, 0x1C),  .vRM, .ZO, .{AVX512BW} ),
    // VPABSW
    instr(.VPABSW,     ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F38,.WIG, 0x1D),  .vRM, .ZO, .{AVX} ),
    instr(.VPABSW,     ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F38,.WIG, 0x1D),  .vRM, .ZO, .{AVX2} ),
    instr(.VPABSW,     ops2(.xmm_kz, .xmm_m128),                   evex(.L128,._66,._0F38,.WIG, 0x1D),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPABSW,     ops2(.ymm_kz, .ymm_m256),                   evex(.L256,._66,._0F38,.WIG, 0x1D),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPABSW,     ops2(.zmm_kz, .zmm_m512),                   evex(.L512,._66,._0F38,.WIG, 0x1D),  .vRM, .ZO, .{AVX512BW} ),
    // VPABSD
    instr(.VPABSD,     ops2(.xmml, .xmml_m128),                     vex(.L128,._66,._0F38,.WIG, 0x1E),  .vRM, .ZO, .{AVX} ),
    instr(.VPABSD,     ops2(.ymml, .ymml_m256),                     vex(.L256,._66,._0F38,.WIG, 0x1E),  .vRM, .ZO, .{AVX2} ),
    instr(.VPABSD,     ops2(.xmm_kz, .xmm_m128_m32bcst),           evex(.L128,._66,._0F38,.W0,  0x1E),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPABSD,     ops2(.ymm_kz, .ymm_m256_m32bcst),           evex(.L256,._66,._0F38,.W0,  0x1E),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPABSD,     ops2(.zmm_kz, .zmm_m512_m32bcst),           evex(.L512,._66,._0F38,.W0,  0x1E),  .vRM, .ZO, .{AVX512F} ),
    // VPABSQ
    instr(.VPABSQ,     ops2(.xmm_kz, .xmm_m128_m64bcst),           evex(.L128,._66,._0F38,.W1,  0x1F),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPABSQ,     ops2(.ymm_kz, .ymm_m256_m64bcst),           evex(.L256,._66,._0F38,.W1,  0x1F),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPABSQ,     ops2(.zmm_kz, .zmm_m512_m64bcst),           evex(.L512,._66,._0F38,.W1,  0x1F),  .vRM, .ZO, .{AVX512F} ),
// VPACKSSWB / PACKSSDW
    // VPACKSSWB
    instr(.VPACKSSWB,  ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,0x63),    .RVM, .ZO, .{AVX} ),
    instr(.VPACKSSWB,  ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG,0x63),    .RVM, .ZO, .{AVX2} ),
    instr(.VPACKSSWB,  ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG,0x63),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKSSWB,  ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG,0x63),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKSSWB,  ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG,0x63),    .RVM, .ZO, .{AVX512BW} ),
    // VPACKSSDW
    instr(.VPACKSSDW,  ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,0x6B),    .RVM, .ZO, .{AVX} ),
    instr(.VPACKSSDW,  ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG,0x6B),    .RVM, .ZO, .{AVX2} ),
    instr(.VPACKSSDW,  ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0, 0x6B),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKSSDW,  ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0, 0x6B),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKSSDW,  ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0, 0x6B),    .RVM, .ZO, .{AVX512BW} ),
// VPACKUSWB
    instr(.VPACKUSWB,  ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,0x67),    .RVM, .ZO, .{AVX} ),
    instr(.VPACKUSWB,  ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG,0x67),    .RVM, .ZO, .{AVX2} ),
    instr(.VPACKUSWB,  ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG,0x67),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKUSWB,  ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG,0x67),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKUSWB,  ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG,0x67),    .RVM, .ZO, .{AVX512BW} ),
// VPACKUSDW
    instr(.VPACKUSDW,  ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG,0x2B),  .RVM, .ZO, .{AVX} ),
    instr(.VPACKUSDW,  ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG,0x2B),  .RVM, .ZO, .{AVX2} ),
    instr(.VPACKUSDW,  ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.W0,0x2B),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKUSDW,  ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.W0,0x2B),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPACKUSDW,  ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.W0,0x2B),   .RVM, .ZO, .{AVX512BW} ),
// VPADDB / PADDW / PADDD / PADDQ
    // VPADDB
    instr(.VPADDB,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xFC),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDB,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xFC),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDB,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xFC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDB,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xFC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDB,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xFC),   .RVM, .ZO, .{AVX512BW} ),
    // VPADDW
    instr(.VPADDW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xFD),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDW,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xFD),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xFD),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDW,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xFD),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDW,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xFD),   .RVM, .ZO, .{AVX512BW} ),
    // VPADDD
    instr(.VPADDD,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xFE),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDD,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xFE),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDD,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xFE),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPADDD,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xFE),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPADDD,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xFE),   .RVM, .ZO, .{AVX512F} ),
    // VPADDQ
    instr(.VPADDQ,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xD4),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDQ,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xD4),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDQ,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xD4),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPADDQ,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xD4),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPADDQ,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xD4),   .RVM, .ZO, .{AVX512F} ),
// VPADDSB / PADDSW
    instr(.VPADDSB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xEC),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDSB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xEC),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDSB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xEC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDSB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xEC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDSB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xEC),   .RVM, .ZO, .{AVX512BW} ),
    //
    instr(.VPADDSW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xED),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDSW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xED),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDSW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xED),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDSW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xED),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDSW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xED),   .RVM, .ZO, .{AVX512BW} ),
// VPADDUSB / PADDUSW
    instr(.VPADDUSB,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDC),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDUSB,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDC),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDUSB,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xDC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDUSB,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xDC),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDUSB,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xDC),   .RVM, .ZO, .{AVX512BW} ),
    //
    instr(.VPADDUSW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDD),   .RVM, .ZO, .{AVX} ),
    instr(.VPADDUSW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDD),   .RVM, .ZO, .{AVX2} ),
    instr(.VPADDUSW,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xDD),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDUSW,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xDD),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPADDUSW,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xDD),   .RVM, .ZO, .{AVX512BW} ),
// VPALIGNR
    instr(.VPALIGNR,   ops4(.xmml, .xmml, .xmml_m128, .imm8),   vex(.L128,._66,._0F3A,.WIG, 0x0F), .RVMI,.ZO, .{AVX} ),
    instr(.VPALIGNR,   ops4(.ymml, .ymml, .ymml_m256, .imm8),   vex(.L256,._66,._0F3A,.WIG, 0x0F), .RVMI,.ZO, .{AVX2} ),
    instr(.VPALIGNR,   ops4(.xmm_kz, .xmm, .xmm_m128, .imm8),  evex(.L128,._66,._0F3A,.WIG, 0x0F), .RVMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPALIGNR,   ops4(.ymm_kz, .ymm, .ymm_m256, .imm8),  evex(.L256,._66,._0F3A,.WIG, 0x0F), .RVMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPALIGNR,   ops4(.zmm_kz, .zmm, .zmm_m512, .imm8),  evex(.L512,._66,._0F3A,.WIG, 0x0F), .RVMI,.ZO, .{AVX512BW} ),
// VPAND
    instr(.VPAND,      ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDB),   .RVM, .ZO, .{AVX} ),
    instr(.VPAND,      ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDB),   .RVM, .ZO, .{AVX2} ),
    instr(.VPANDD,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xDB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDD,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xDB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDD,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xDB),   .RVM, .ZO, .{AVX512F} ),
    instr(.VPANDQ,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xDB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDQ,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xDB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDQ,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xDB),   .RVM, .ZO, .{AVX512F} ),
// VPANDN
    instr(.VPANDN,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDF),   .RVM, .ZO, .{AVX} ),
    instr(.VPANDN,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDF),   .RVM, .ZO, .{AVX2} ),
    instr(.VPANDND,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xDF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDND,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xDF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDND,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xDF),   .RVM, .ZO, .{AVX512F} ),
    instr(.VPANDNQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xDF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDNQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xDF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPANDNQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xDF),   .RVM, .ZO, .{AVX512F} ),
// VPAVGB / VPAVGW
    instr(.VPAVGB,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE0),   .RVM, .ZO, .{AVX} ),
    instr(.VPAVGB,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE0),   .RVM, .ZO, .{AVX2} ),
    instr(.VPAVGB,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE0),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPAVGB,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE0),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPAVGB,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE0),   .RVM, .ZO, .{AVX512BW} ),
    //
    instr(.VPAVGW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE3),   .RVM, .ZO, .{AVX} ),
    instr(.VPAVGW,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE3),   .RVM, .ZO, .{AVX2} ),
    instr(.VPAVGW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE3),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPAVGW,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE3),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPAVGW,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE3),   .RVM, .ZO, .{AVX512BW} ),
// VPBLENDVB
    instr(.VPBLENDVB,  ops4(.xmml, .xmml, .xmml_m128, .xmml),   vex(.L128,._66,._0F3A,.W0,0x4C),   .RVMR,.ZO, .{AVX} ),
    instr(.VPBLENDVB,  ops4(.ymml, .ymml, .ymml_m256, .ymml),   vex(.L256,._66,._0F3A,.W0,0x4C),   .RVMR,.ZO, .{AVX2} ),
// VPBLENDDW
    instr(.VPBLENDW,   ops4(.xmml, .xmml, .xmml_m128, .imm8),   vex(.L128,._66,._0F3A,.WIG,0x0E),  .RVMI,.ZO, .{AVX} ),
    instr(.VPBLENDW,   ops4(.ymml, .ymml, .ymml_m256, .imm8),   vex(.L256,._66,._0F3A,.WIG,0x0E),  .RVMI,.ZO, .{AVX2} ),
// VPCLMULQDQ
    instr(.VPCLMULQDQ, ops4(.xmml, .xmml, .xmml_m128, .imm8),   vex(.L128,._66,._0F3A,.WIG,0x44),  .RVMI,.ZO, .{AVX, PCLMULQDQ} ),
    instr(.VPCLMULQDQ, ops4(.ymml, .ymml, .ymml_m256, .imm8),   vex(.L256,._66,._0F3A,.WIG,0x44),  .RVMI,.ZO, .{VPCLMULQDQ} ),
    instr(.VPCLMULQDQ, ops4(.xmm, .xmm, .xmm_m128, .imm8),     evex(.L128,._66,._0F3A,.WIG,0x44),  .RVMI,.ZO, .{VPCLMULQDQ, AVX512VL} ),
    instr(.VPCLMULQDQ, ops4(.ymm, .ymm, .ymm_m256, .imm8),     evex(.L256,._66,._0F3A,.WIG,0x44),  .RVMI,.ZO, .{VPCLMULQDQ, AVX512VL} ),
    instr(.VPCLMULQDQ, ops4(.zmm, .zmm, .zmm_m512, .imm8),     evex(.L512,._66,._0F3A,.WIG,0x44),  .RVMI,.ZO, .{VPCLMULQDQ, AVX512F} ),
// VPCMPEQB / VPCMPEQW / VPCMPEQD
    instr(.VPCMPEQB,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x74),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPEQB,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x74),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPEQB,   ops3(.reg_k_k, .xmm, .xmm_m128),        evex(.L128,._66,._0F,.WIG, 0x74),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPEQB,   ops3(.reg_k_k, .ymm, .ymm_m256),        evex(.L256,._66,._0F,.WIG, 0x74),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPEQB,   ops3(.reg_k_k, .zmm, .zmm_m512),        evex(.L512,._66,._0F,.WIG, 0x74),   .RVM, .ZO, .{AVX512BW} ),
    // VPCMPEQW
    instr(.VPCMPEQW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x75),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPEQW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x75),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPEQW,   ops3(.reg_k_k, .xmm, .xmm_m128),        evex(.L128,._66,._0F,.WIG, 0x75),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPEQW,   ops3(.reg_k_k, .ymm, .ymm_m256),        evex(.L256,._66,._0F,.WIG, 0x75),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPEQW,   ops3(.reg_k_k, .zmm, .zmm_m512),        evex(.L512,._66,._0F,.WIG, 0x75),   .RVM, .ZO, .{AVX512BW} ),
    // VPCMPEQD
    instr(.VPCMPEQD,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x76),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPEQD,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x76),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPEQD,   ops3(.reg_k_k, .xmm, .xmm_m128_m32bcst),evex(.L128,._66,._0F,.W0,  0x76),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPEQD,   ops3(.reg_k_k, .ymm, .ymm_m256_m32bcst),evex(.L256,._66,._0F,.W0,  0x76),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPEQD,   ops3(.reg_k_k, .zmm, .zmm_m512_m32bcst),evex(.L512,._66,._0F,.W0,  0x76),   .RVM, .ZO, .{AVX512F} ),
// VPCMPEQQ
    instr(.VPCMPEQQ,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x29), .RVM, .ZO, .{AVX} ),
    instr(.VPCMPEQQ,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x29), .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPEQQ,   ops3(.reg_k_k, .xmm, .xmm_m128_m64bcst),evex(.L128,._66,._0F38,.W1,  0x29), .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPEQQ,   ops3(.reg_k_k, .ymm, .ymm_m256_m64bcst),evex(.L256,._66,._0F38,.W1,  0x29), .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPEQQ,   ops3(.reg_k_k, .zmm, .zmm_m512_m64bcst),evex(.L512,._66,._0F38,.W1,  0x29), .RVM, .ZO, .{AVX512F} ),
// VPCMPESTRI
    instr(.VPCMPESTRI, ops3(.xmml,.xmml_m128,.imm8),            vex(.L128,._66,._0F3A,.WIG, 0x61), .vRMI,.ZO, .{AVX} ),
// VPCMPESTRM
    instr(.VPCMPESTRM, ops3(.xmml,.xmml_m128,.imm8),            vex(.L128,._66,._0F3A,.WIG, 0x60), .vRMI,.ZO, .{AVX} ),
// VPCMPGTB / VPCMPGTW / VPCMPGTD
    instr(.VPCMPGTB,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x64),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPGTB,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x64),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPGTB,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0x64),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPGTB,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0x64),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPGTB,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0x64),   .RVM, .ZO, .{AVX512BW} ),
    // VPCMPGTW
    instr(.VPCMPGTW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x65),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPGTW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x65),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPGTW,   ops3(.reg_k_k,.xmm,.xmm_m128),          evex(.L128,._66,._0F,.WIG, 0x65),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPGTW,   ops3(.reg_k_k,.ymm,.ymm_m256),          evex(.L256,._66,._0F,.WIG, 0x65),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPCMPGTW,   ops3(.reg_k_k,.zmm,.zmm_m512),          evex(.L512,._66,._0F,.WIG, 0x65),   .RVM, .ZO, .{AVX512BW} ),
    // VPCMPGTD
    instr(.VPCMPGTD,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x66),   .RVM, .ZO, .{AVX} ),
    instr(.VPCMPGTD,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x66),   .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPGTD,   ops3(.reg_k_k,.xmm,.xmm_m128_m32bcst),  evex(.L128,._66,._0F,.W0,  0x66),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPGTD,   ops3(.reg_k_k,.ymm,.ymm_m256_m32bcst),  evex(.L256,._66,._0F,.W0,  0x66),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPGTD,   ops3(.reg_k_k,.zmm,.zmm_m512_m32bcst),  evex(.L512,._66,._0F,.W0,  0x66),   .RVM, .ZO, .{AVX512F} ),
// VPCMPGTQ
    instr(.VPCMPGTQ,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x37), .RVM, .ZO, .{AVX} ),
    instr(.VPCMPGTQ,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x37), .RVM, .ZO, .{AVX2} ),
    instr(.VPCMPGTQ,   ops3(.reg_k_k,.xmm,.xmm_m128_m64bcst),  evex(.L128,._66,._0F38,.W1,  0x37), .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPGTQ,   ops3(.reg_k_k,.ymm,.ymm_m256_m64bcst),  evex(.L256,._66,._0F38,.W1,  0x37), .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPCMPGTQ,   ops3(.reg_k_k,.zmm,.zmm_m512_m64bcst),  evex(.L512,._66,._0F38,.W1,  0x37), .RVM, .ZO, .{AVX512F} ),
// VPCMPISTRI
    instr(.VPCMPISTRI, ops3(.xmml,.xmml_m128,.imm8),            vex(.L128,._66,._0F3A,.WIG, 0x63), .vRMI,.ZO, .{AVX} ),
// VPCMPISTRM
    instr(.VPCMPISTRM, ops3(.xmml,.xmml_m128,.imm8),            vex(.L128,._66,._0F3A,.WIG, 0x62), .vRMI,.ZO, .{AVX} ),
// VPEXTRB / VPEXTRD / VPEXTRQ
    instr(.VPEXTRB,    ops3(.rm_mem8, .xmml, .imm8),            vex(.L128,._66,._0F3A,.W0,  0x14), .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRB,    ops3(.rm_reg32, .xmml, .imm8),           vex(.L128,._66,._0F3A,.W0,  0x14), .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRB,    ops3(.rm_reg64, .xmml, .imm8),           vex(.L128,._66,._0F3A,.W0,  0x14), .vMRI,.ZO, .{AVX, No32} ),
    instr(.VPEXTRB,    ops3(.rm_mem8, .xmm, .imm8),            evex(.L128,._66,._0F3A,.WIG, 0x14), .vMRI,.ZO, .{AVX512BW} ),
    instr(.VPEXTRB,    ops3(.reg32, .xmm, .imm8),              evex(.L128,._66,._0F3A,.WIG, 0x14), .vMRI,.ZO, .{AVX512BW} ),
    instr(.VPEXTRB,    ops3(.reg64, .xmm, .imm8),              evex(.L128,._66,._0F3A,.WIG, 0x14), .vMRI,.ZO, .{AVX512BW, No32} ),
    //
    instr(.VPEXTRD,    ops3(.rm32, .xmml, .imm8),               vex(.L128,._66,._0F3A,.W0,  0x16), .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRD,    ops3(.rm32, .xmm, .imm8),               evex(.L128,._66,._0F3A,.W0,  0x16), .vMRI,.ZO, .{AVX512DQ} ),
    //
    instr(.VPEXTRQ,    ops3(.rm64, .xmml, .imm8),               vex(.L128,._66,._0F3A,.W1,  0x16), .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRQ,    ops3(.rm64, .xmm, .imm8),               evex(.L128,._66,._0F3A,.W1,  0x16), .vMRI,.ZO, .{AVX512DQ} ),
// VPEXTRW
    instr(.VPEXTRW,    ops3(.reg32, .xmml, .imm8),              vex(.L128,._66,._0F,.W0, 0xC5),    .vRMI,.ZO, .{AVX} ),
    instr(.VPEXTRW,    ops3(.reg64, .xmml, .imm8),              vex(.L128,._66,._0F,.W0, 0xC5),    .vRMI,.ZO, .{AVX, No32} ),
    instr(.VPEXTRW,    ops3(.rm_mem16, .xmml, .imm8),           vex(.L128,._66,._0F3A,.W0, 0x15),  .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRW,    ops3(.rm_reg32, .xmml, .imm8),           vex(.L128,._66,._0F3A,.W0, 0x15),  .vMRI,.ZO, .{AVX} ),
    instr(.VPEXTRW,    ops3(.rm_reg64, .xmml, .imm8),           vex(.L128,._66,._0F3A,.W0, 0x15),  .vMRI,.ZO, .{AVX, No32} ),
    instr(.VPEXTRW,    ops3(.reg32, .xmm, .imm8),              evex(.L128,._66,._0F,.WIG, 0xC5),   .vRMI,.ZO, .{AVX512BW} ),
    instr(.VPEXTRW,    ops3(.reg64, .xmm, .imm8),              evex(.L128,._66,._0F,.WIG, 0xC5),   .vRMI,.ZO, .{AVX512BW, No32} ),
    instr(.VPEXTRW,    ops3(.rm_mem16, .xmm, .imm8),           evex(.L128,._66,._0F3A,.WIG, 0x15), .vMRI,.ZO, .{AVX512BW} ),
    instr(.VPEXTRW,    ops3(.rm_reg32, .xmm, .imm8),           evex(.L128,._66,._0F3A,.WIG, 0x15), .vMRI,.ZO, .{AVX512BW} ),
    instr(.VPEXTRW,    ops3(.rm_reg64, .xmm, .imm8),           evex(.L128,._66,._0F3A,.WIG, 0x15), .vMRI,.ZO, .{AVX512BW, No32} ),
// VPHADDW / VPHADDD
    instr(.VPHADDW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x01),   .RVM, .ZO, .{AVX} ),
    instr(.VPHADDW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x01),   .RVM, .ZO, .{AVX2} ),
    //
    instr(.VPHADDD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x02),   .RVM, .ZO, .{AVX} ),
    instr(.VPHADDD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x02),   .RVM, .ZO, .{AVX2} ),
// VPHADDSW
    instr(.VPHADDSW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x03),   .RVM, .ZO, .{AVX} ),
    instr(.VPHADDSW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x03),   .RVM, .ZO, .{AVX2} ),
// VPHMINPOSUW
    instr(.VPHMINPOSUW,ops2(.xmml, .xmml_m128),                 vex(.L128,._66,._0F38,.WIG, 0x41),   .vRM, .ZO, .{AVX} ),
// VPHSUBW / VPHSUBD
    instr(.VPHSUBW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x05),   .RVM, .ZO, .{AVX} ),
    instr(.VPHSUBW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x05),   .RVM, .ZO, .{AVX2} ),
    //
    instr(.VPHSUBD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x06),   .RVM, .ZO, .{AVX} ),
    instr(.VPHSUBD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x06),   .RVM, .ZO, .{AVX2} ),
// VPHSUBSW
    instr(.VPHSUBSW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x07),   .RVM, .ZO, .{AVX} ),
    instr(.VPHSUBSW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x07),   .RVM, .ZO, .{AVX2} ),
// VPINSRB / VPINSRD / VPINSRQ
    instr(.VPINSRB,    ops4(.xmml, .xmml, .rm_mem8, .imm8),     vex(.L128,._66,._0F3A,.W0,  0x20),   .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRB,    ops4(.xmml, .xmml, .rm_reg32, .imm8),    vex(.L128,._66,._0F3A,.W0,  0x20),   .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRB,    ops4(.xmm, .xmm, .rm_mem8, .imm8),      evex(.L128,._66,._0F3A,.WIG, 0x20),   .RVMI,.ZO, .{AVX512BW} ),
    instr(.VPINSRB,    ops4(.xmm, .xmm, .rm_reg32, .imm8),     evex(.L128,._66,._0F3A,.WIG, 0x20),   .RVMI,.ZO, .{AVX512BW} ),
    //
    instr(.VPINSRD,    ops4(.xmml, .xmml, .rm32, .imm8),        vex(.L128,._66,._0F3A,.W0,  0x22),   .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRD,    ops4(.xmm, .xmm, .rm32, .imm8),         evex(.L128,._66,._0F3A,.W0,  0x22),   .RVMI,.ZO, .{AVX512DQ} ),
    //
    instr(.VPINSRQ,    ops4(.xmml, .xmml, .rm64, .imm8),        vex(.L128,._66,._0F3A,.W1,  0x22),   .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRQ,    ops4(.xmm, .xmm, .rm64, .imm8),         evex(.L128,._66,._0F3A,.W1,  0x22),   .RVMI,.ZO, .{AVX512DQ} ),
// VPINSRW
    instr(.VPINSRW,    ops4(.xmml, .xmml, .rm_mem16, .imm8),    vex(.L128,._66,._0F,.W0,  0xC4),     .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRW,    ops4(.xmml, .xmml, .rm_reg32, .imm8),    vex(.L128,._66,._0F,.W0,  0xC4),     .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRW,    ops4(.xmml, .xmml, .rm_reg64, .imm8),    vex(.L128,._66,._0F,.W0,  0xC4),     .RVMI,.ZO, .{AVX} ),
    instr(.VPINSRW,    ops4(.xmm, .xmm, .rm_mem16, .imm8),     evex(.L128,._66,._0F,.WIG, 0xC4),     .RVMI,.ZO, .{AVX512BW} ),
    instr(.VPINSRW,    ops4(.xmm, .xmm, .rm_reg32, .imm8),     evex(.L128,._66,._0F,.WIG, 0xC4),     .RVMI,.ZO, .{AVX512BW} ),
    instr(.VPINSRW,    ops4(.xmm, .xmm, .rm_reg64, .imm8),     evex(.L128,._66,._0F,.WIG, 0xC4),     .RVMI,.ZO, .{AVX512BW} ),
// VPMADDUBSW
    instr(.VPMADDUBSW, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x04),   .RVM, .ZO, .{AVX} ),
    instr(.VPMADDUBSW, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x04),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMADDUBSW, ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x04),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMADDUBSW, ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x04),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMADDUBSW, ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x04),   .RVM, .ZO, .{AVX512BW} ),
// VPMADDWD
    instr(.VPMADDWD,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xF5),     .RVM, .ZO, .{AVX} ),
    instr(.VPMADDWD,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xF5),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMADDWD,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xF5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMADDWD,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xF5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMADDWD,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xF5),     .RVM, .ZO, .{AVX512BW} ),
// VPMAXSB / VPMAXSW / VPMAXSD / VPMAXSQ
    // VPMAXSB
    instr(.VPMAXSB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3C),   .RVM, .ZO, .{AVX} ),
    instr(.VPMAXSB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3C),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXSB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x3C),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXSB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x3C),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXSB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x3C),   .RVM, .ZO, .{AVX512BW} ),
    // VPMAXSW
    instr(.VPMAXSW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xEE),     .RVM, .ZO, .{AVX} ),
    instr(.VPMAXSW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xEE),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXSW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xEE),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXSW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xEE),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXSW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xEE),     .RVM, .ZO, .{AVX512BW} ),
    // VPMAXSD
    instr(.VPMAXSD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3D),   .RVM, .ZO, .{AVX} ),
    instr(.VPMAXSD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3D),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXSD,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F38,.W0,  0x3D),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXSD,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F38,.W0,  0x3D),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXSD,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F38,.W0,  0x3D),   .RVM, .ZO, .{AVX512F} ),
    // VPMAXSQ
    instr(.VPMAXSQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x3D),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXSQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x3D),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXSQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x3D),   .RVM, .ZO, .{AVX512F} ),
// VPMAXUB / VPMAXUW
    // VPMAXUB
    instr(.VPMAXUB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDE),     .RVM, .ZO, .{AVX} ),
    instr(.VPMAXUB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDE),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXUB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xDE),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXUB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xDE),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXUB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xDE),     .RVM, .ZO, .{AVX512BW} ),
    // VPMAXUW
    instr(.VPMAXUW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3E),   .RVM, .ZO, .{AVX} ),
    instr(.VPMAXUW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3E),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXUW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x3E),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXUW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x3E),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMAXUW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x3E),   .RVM, .ZO, .{AVX512BW} ),
// VPMAXUD / VPMAXUQ
    // VPMAXUD
    instr(.VPMAXUD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3F),   .RVM, .ZO, .{AVX} ),
    instr(.VPMAXUD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3F),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMAXUD,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F38,.W0,  0x3F),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXUD,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F38,.W0,  0x3F),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXUD,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F38,.W0,  0x3F),   .RVM, .ZO, .{AVX512F} ),
    // VPMAXUQ
    instr(.VPMAXUQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x3F),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXUQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x3F),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMAXUQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x3F),   .RVM, .ZO, .{AVX512F} ),
// VPMINSB / VPMINSW
    // VPMINSB
    instr(.VPMINSB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x38),   .RVM, .ZO, .{AVX} ),
    instr(.VPMINSB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x38),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMINSB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x38),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINSB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x38),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINSB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x38),   .RVM, .ZO, .{AVX512BW} ),
    // VPMINSW
    instr(.VPMINSW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xEA),     .RVM, .ZO, .{AVX} ),
    instr(.VPMINSW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xEA),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMINSW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xEA),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINSW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xEA),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINSW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xEA),     .RVM, .ZO, .{AVX512BW} ),
// VPMINSD / VPMINSQ
    // VPMINSD
    instr(.VPMINSD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x39),   .RVM, .ZO, .{AVX} ),
    instr(.VPMINSD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x39),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMINSD,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F38,.W0,  0x39),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINSD,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F38,.W0,  0x39),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINSD,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F38,.W0,  0x39),   .RVM, .ZO, .{AVX512F} ),
    // VPMINSQ
    instr(.VPMINSQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x39),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINSQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x39),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINSQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x39),   .RVM, .ZO, .{AVX512F} ),
// VPMINUB / VPMINUW
    // VPMINUB
    instr(.VPMINUB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xDA),     .RVM, .ZO, .{AVX} ),
    instr(.VPMINUB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xDA),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMINUB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xDA),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINUB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xDA),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINUB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xDA),     .RVM, .ZO, .{AVX512BW} ),
    // VPMINUW
    instr(.VPMINUW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3A),   .RVM, .ZO, .{AVX} ),
    instr(.VPMINUW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3A),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMINUW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x3A),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINUW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x3A),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMINUW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x3A),   .RVM, .ZO, .{AVX512BW} ),
// VPMINUD / VPMINUQ
    // VPMINUD
    instr(.VPMINUD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x3B),   .RVM, .ZO, .{AVX} ),
    instr(.VPMINUD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x3B),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMINUD,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F38,.W0,  0x3B),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINUD,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F38,.W0,  0x3B),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINUD,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F38,.W0,  0x3B),   .RVM, .ZO, .{AVX512F} ),
    // VPMINUQ
    instr(.VPMINUQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x3B),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINUQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x3B),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMINUQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x3B),   .RVM, .ZO, .{AVX512F} ),
// VPMOVMSKB
    instr(.VPMOVMSKB,  ops2(.reg32, .xmml_m128),                vex(.L128,._66,._0F,.WIG, 0xD7),     .RVM, .ZO, .{AVX} ),
    instr(.VPMOVMSKB,  ops2(.reg64, .xmml_m128),                vex(.L128,._66,._0F,.WIG, 0xD7),     .RVM, .ZO, .{AVX} ),
    instr(.VPMOVMSKB,  ops2(.reg32, .ymml_m256),                vex(.L256,._66,._0F,.WIG, 0xD7),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMOVMSKB,  ops2(.reg64, .ymml_m256),                vex(.L256,._66,._0F,.WIG, 0xD7),     .RVM, .ZO, .{AVX2} ),
// VPMOVSX
    // VPMOVSXBW
    instr(.VPMOVSXBW,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x20),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXBW,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x20),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXBW,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.WIG, 0x20),   .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMOVSXBW,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.WIG, 0x20),   .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMOVSXBW,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.WIG, 0x20),   .vRM, .ZO, .{AVX512BW} ),
    // VPMOVSXBD
    instr(.VPMOVSXBD,  ops2(.xmml, .xmml_m32),                  vex(.L128,._66,._0F38,.WIG, 0x21),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXBD,  ops2(.ymml, .xmml_m64),                  vex(.L256,._66,._0F38,.WIG, 0x21),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXBD,  ops2(.xmm_kz, .xmm_m32),                evex(.L128,._66,._0F38,.WIG, 0x21),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXBD,  ops2(.ymm_kz, .xmm_m64),                evex(.L256,._66,._0F38,.WIG, 0x21),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXBD,  ops2(.zmm_kz, .xmm_m128),               evex(.L512,._66,._0F38,.WIG, 0x21),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVSXBQ
    instr(.VPMOVSXBQ,  ops2(.xmml, .xmml_m16),                  vex(.L128,._66,._0F38,.WIG, 0x22),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXBQ,  ops2(.ymml, .xmml_m32),                  vex(.L256,._66,._0F38,.WIG, 0x22),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXBQ,  ops2(.xmm_kz, .xmm_m16),                evex(.L128,._66,._0F38,.WIG, 0x22),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXBQ,  ops2(.ymm_kz, .xmm_m32),                evex(.L256,._66,._0F38,.WIG, 0x22),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXBQ,  ops2(.zmm_kz, .xmm_m64),                evex(.L512,._66,._0F38,.WIG, 0x22),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVSXWD
    instr(.VPMOVSXWD,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x23),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXWD,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x23),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXWD,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.WIG, 0x23),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXWD,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.WIG, 0x23),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXWD,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.WIG, 0x23),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVSXWQ
    instr(.VPMOVSXWQ,  ops2(.xmml, .xmml_m32),                  vex(.L128,._66,._0F38,.WIG, 0x24),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXWQ,  ops2(.ymml, .xmml_m64),                  vex(.L256,._66,._0F38,.WIG, 0x24),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXWQ,  ops2(.xmm_kz, .xmm_m32),                evex(.L128,._66,._0F38,.WIG, 0x24),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXWQ,  ops2(.ymm_kz, .xmm_m64),                evex(.L256,._66,._0F38,.WIG, 0x24),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXWQ,  ops2(.zmm_kz, .xmm_m128),               evex(.L512,._66,._0F38,.WIG, 0x24),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVSXDQ
    instr(.VPMOVSXDQ,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x25),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVSXDQ,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x25),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVSXDQ,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.W0,  0x25),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXDQ,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.W0,  0x25),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVSXDQ,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.W0,  0x25),   .vRM, .ZO, .{AVX512F} ),
// VPMOVZX
    // VPMOVZXBW
    instr(.VPMOVZXBW,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x30),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXBW,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x30),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXBW,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.WIG, 0x30),   .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMOVZXBW,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.WIG, 0x30),   .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMOVZXBW,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.WIG, 0x30),   .vRM, .ZO, .{AVX512BW} ),
    // VPMOVZXBD
    instr(.VPMOVZXBD,  ops2(.xmml, .xmml_m32),                  vex(.L128,._66,._0F38,.WIG, 0x31),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXBD,  ops2(.ymml, .xmml_m64),                  vex(.L256,._66,._0F38,.WIG, 0x31),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXBD,  ops2(.xmm_kz, .xmm_m32),                evex(.L128,._66,._0F38,.WIG, 0x31),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXBD,  ops2(.ymm_kz, .xmm_m64),                evex(.L256,._66,._0F38,.WIG, 0x31),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXBD,  ops2(.zmm_kz, .xmm_m128),               evex(.L512,._66,._0F38,.WIG, 0x31),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVZXBQ
    instr(.VPMOVZXBQ,  ops2(.xmml, .xmml_m16),                  vex(.L128,._66,._0F38,.WIG, 0x32),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXBQ,  ops2(.ymml, .xmml_m32),                  vex(.L256,._66,._0F38,.WIG, 0x32),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXBQ,  ops2(.xmm_kz, .xmm_m16),                evex(.L128,._66,._0F38,.WIG, 0x32),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXBQ,  ops2(.ymm_kz, .xmm_m32),                evex(.L256,._66,._0F38,.WIG, 0x32),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXBQ,  ops2(.zmm_kz, .xmm_m64),                evex(.L512,._66,._0F38,.WIG, 0x32),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVZXWD
    instr(.VPMOVZXWD,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x33),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXWD,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x33),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXWD,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.WIG, 0x33),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXWD,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.WIG, 0x33),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXWD,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.WIG, 0x33),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVZXWQ
    instr(.VPMOVZXWQ,  ops2(.xmml, .xmml_m32),                  vex(.L128,._66,._0F38,.WIG, 0x34),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXWQ,  ops2(.ymml, .xmml_m64),                  vex(.L256,._66,._0F38,.WIG, 0x34),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXWQ,  ops2(.xmm_kz, .xmm_m32),                evex(.L128,._66,._0F38,.WIG, 0x34),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXWQ,  ops2(.ymm_kz, .xmm_m64),                evex(.L256,._66,._0F38,.WIG, 0x34),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXWQ,  ops2(.zmm_kz, .xmm_m128),               evex(.L512,._66,._0F38,.WIG, 0x34),   .vRM, .ZO, .{AVX512F} ),
    // VPMOVZXDQ
    instr(.VPMOVZXDQ,  ops2(.xmml, .xmml_m64),                  vex(.L128,._66,._0F38,.WIG, 0x35),   .vRM, .ZO, .{AVX} ),
    instr(.VPMOVZXDQ,  ops2(.ymml, .xmml_m128),                 vex(.L256,._66,._0F38,.WIG, 0x35),   .vRM, .ZO, .{AVX2} ),
    instr(.VPMOVZXDQ,  ops2(.xmm_kz, .xmm_m64),                evex(.L128,._66,._0F38,.W0,  0x35),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXDQ,  ops2(.ymm_kz, .xmm_m128),               evex(.L256,._66,._0F38,.W0,  0x35),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMOVZXDQ,  ops2(.zmm_kz, .ymm_m256),               evex(.L512,._66,._0F38,.W0,  0x35),   .vRM, .ZO, .{AVX512F} ),
// VPMULDQ
    instr(.VPMULDQ,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x28),   .RVM, .ZO, .{AVX} ),
    instr(.VPMULDQ,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x28),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMULDQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x28),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULDQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x28),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULDQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x28),   .RVM, .ZO, .{AVX512F} ),
// VPMULHRSW
    instr(.VPMULHRSW,  ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x0B),   .RVM, .ZO, .{AVX} ),
    instr(.VPMULHRSW,  ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x0B),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMULHRSW,  ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x0B),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHRSW,  ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x0B),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHRSW,  ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x0B),   .RVM, .ZO, .{AVX512BW} ),
// VPMULHUW
    instr(.VPMULHUW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE4),     .RVM, .ZO, .{AVX} ),
    instr(.VPMULHUW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE4),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMULHUW,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE4),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHUW,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE4),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHUW,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE4),     .RVM, .ZO, .{AVX512BW} ),
// VPMULHW
    instr(.VPMULHW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE5),     .RVM, .ZO, .{AVX} ),
    instr(.VPMULHW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE5),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMULHW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULHW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE5),     .RVM, .ZO, .{AVX512BW} ),
// VPMULLD / VPMULLQ
    // VPMULLD
    instr(.VPMULLD,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x40),   .RVM, .ZO, .{AVX} ),
    instr(.VPMULLD,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x40),   .RVM, .ZO, .{AVX2} ),
    instr(.VPMULLD,    ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F38,.W0,  0x40),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULLD,    ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F38,.W0,  0x40),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULLD,    ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F38,.W0,  0x40),   .RVM, .ZO, .{AVX512F} ),
    // VPMULLQ
    instr(.VPMULLQ,    ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F38,.W1,  0x40),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VPMULLQ,    ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F38,.W1,  0x40),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VPMULLQ,    ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F38,.W1,  0x40),   .RVM, .ZO, .{AVX512DQ} ),
// VPMULLW
    instr(.VPMULLW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xD5),     .RVM, .ZO, .{AVX} ),
    instr(.VPMULLW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xD5),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMULLW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xD5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULLW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xD5),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPMULLW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xD5),     .RVM, .ZO, .{AVX512BW} ),
// VPMULUDQ
    instr(.VPMULUDQ,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xF4),     .RVM, .ZO, .{AVX} ),
    instr(.VPMULUDQ,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xF4),     .RVM, .ZO, .{AVX2} ),
    instr(.VPMULUDQ,   ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xF4),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULUDQ,   ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xF4),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPMULUDQ,   ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xF4),     .RVM, .ZO, .{AVX512F} ),
// VPOR
    instr(.VPOR,       ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xEB),     .RVM, .ZO, .{AVX} ),
    instr(.VPOR,       ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xEB),     .RVM, .ZO, .{AVX2} ),
    //
    instr(.VPORD,      ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xEB),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPORD,      ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xEB),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPORD,      ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xEB),     .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VPORQ,      ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xEB),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPORQ,      ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xEB),     .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPORQ,      ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xEB),     .RVM, .ZO, .{AVX512F} ),
// VPSADBW
    instr(.VPSADBW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xF6),     .RVM, .ZO, .{AVX} ),
    instr(.VPSADBW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xF6),     .RVM, .ZO, .{AVX2} ),
    instr(.VPSADBW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xF6),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSADBW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xF6),     .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSADBW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xF6),     .RVM, .ZO, .{AVX512BW} ),
// VPSHUFB
    instr(.VPSHUFB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x00),   .RVM, .ZO, .{AVX} ),
    instr(.VPSHUFB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x00),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSHUFB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F38,.WIG, 0x00),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F38,.WIG, 0x00),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F38,.WIG, 0x00),   .RVM, .ZO, .{AVX512BW} ),
// VPSHUFD
    instr(.VPSHUFD,    ops3(.xmml, .xmml_m128, .imm8),          vex(.L128,._66,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX} ),
    instr(.VPSHUFD,    ops3(.ymml, .ymml_m256, .imm8),          vex(.L256,._66,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX2} ),
    instr(.VPSHUFD,    ops3(.xmm_kz, .xmm_m128_m32bcst, .imm8),evex(.L128,._66,._0F,.W0,  0x70),     .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSHUFD,    ops3(.ymm_kz, .ymm_m256_m32bcst, .imm8),evex(.L256,._66,._0F,.W0,  0x70),     .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSHUFD,    ops3(.zmm_kz, .zmm_m512_m32bcst, .imm8),evex(.L512,._66,._0F,.W0,  0x70),     .vRMI,.ZO, .{AVX512F} ),
// VPSHUFHW
    instr(.VPSHUFHW,   ops3(.xmml, .xmml_m128, .imm8),          vex(.L128,._F3,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX} ),
    instr(.VPSHUFHW,   ops3(.ymml, .ymml_m256, .imm8),          vex(.L256,._F3,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX2} ),
    instr(.VPSHUFHW,   ops3(.xmm_kz, .xmm_m128, .imm8),        evex(.L128,._F3,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFHW,   ops3(.ymm_kz, .ymm_m256, .imm8),        evex(.L256,._F3,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFHW,   ops3(.zmm_kz, .zmm_m512, .imm8),        evex(.L512,._F3,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512BW} ),
// VPSHUFLW
    instr(.VPSHUFLW,   ops3(.xmml, .xmml_m128, .imm8),          vex(.L128,._F2,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX} ),
    instr(.VPSHUFLW,   ops3(.ymml, .ymml_m256, .imm8),          vex(.L256,._F2,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX2} ),
    instr(.VPSHUFLW,   ops3(.xmm_kz, .xmm_m128, .imm8),        evex(.L128,._F2,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFLW,   ops3(.ymm_kz, .ymm_m256, .imm8),        evex(.L256,._F2,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSHUFLW,   ops3(.zmm_kz, .zmm_m512, .imm8),        evex(.L512,._F2,._0F,.WIG, 0x70),     .vRMI,.ZO, .{AVX512BW} ),
// VPSIGNB / VPSIGNW / VPSIGND
    // VPSIGNB
    instr(.VPSIGNB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x08),   .RVM, .ZO, .{AVX} ),
    instr(.VPSIGNB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x08),   .RVM, .ZO, .{AVX2} ),
    // VPSIGNW
    instr(.VPSIGNW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x09),   .RVM, .ZO, .{AVX} ),
    instr(.VPSIGNW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x09),   .RVM, .ZO, .{AVX2} ),
    // VPSIGND
    instr(.VPSIGND,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F38,.WIG, 0x0A),   .RVM, .ZO, .{AVX} ),
    instr(.VPSIGND,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F38,.WIG, 0x0A),   .RVM, .ZO, .{AVX2} ),
// VPSLLDQ
    instr(.VPSLLDQ,    ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x73, 7), .VMI, .ZO, .{AVX} ),
    instr(.VPSLLDQ,    ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x73, 7), .VMI, .ZO, .{AVX2} ),
    instr(.VPSLLDQ,    ops3(.xmm_kz, .xmm_m128, .imm8),        evexr(.L128,._66,._0F,.WIG, 0x73, 7), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLDQ,    ops3(.ymm_kz, .ymm_m256, .imm8),        evexr(.L256,._66,._0F,.WIG, 0x73, 7), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLDQ,    ops3(.zmm_kz, .zmm_m512, .imm8),        evexr(.L512,._66,._0F,.WIG, 0x73, 7), .VMI, .ZO, .{AVX512BW} ),
// VPSLLW / VPSLLD / VPSLLQ
    // VPSLLW
    instr(.VPSLLW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xF1),    .RVM, .ZO, .{AVX} ),
    instr(.VPSLLW,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x71, 6), .VMI, .ZO, .{AVX} ),
    instr(.VPSLLW,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xF1),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSLLW,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x71, 6), .VMI, .ZO, .{AVX2} ),
    instr(.VPSLLW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG,  0xF1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLW,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.WIG,  0xF1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLW,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.WIG,  0xF1),    .RVM, .ZO, .{AVX512BW} ),
    instr(.VPSLLW,     ops3(.xmm_kz, .xmm_m128, .imm8),        evexr(.L128,._66,._0F,.WIG, 0x71, 6), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLW,     ops3(.ymm_kz, .ymm_m256, .imm8),        evexr(.L256,._66,._0F,.WIG, 0x71, 6), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSLLW,     ops3(.zmm_kz, .zmm_m512, .imm8),        evexr(.L512,._66,._0F,.WIG, 0x71, 6), .VMI, .ZO, .{AVX512BW} ),
    // VPSLLD
    instr(.VPSLLD,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xF2),    .RVM, .ZO, .{AVX} ),
    instr(.VPSLLD,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x72, 6), .VMI, .ZO, .{AVX} ),
    instr(.VPSLLD,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xF2),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSLLD,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x72, 6), .VMI, .ZO, .{AVX2} ),
    instr(.VPSLLD,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W0,   0xF2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLD,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W0,   0xF2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLD,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W0,   0xF2),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSLLD,     ops3(.xmm_kz, .xmm_m128_m32bcst, .imm8),evexr(.L128,._66,._0F,.W0,  0x72, 6), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLD,     ops3(.ymm_kz, .ymm_m256_m32bcst, .imm8),evexr(.L256,._66,._0F,.W0,  0x72, 6), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLD,     ops3(.zmm_kz, .zmm_m512_m32bcst, .imm8),evexr(.L512,._66,._0F,.W0,  0x72, 6), .VMI, .ZO, .{AVX512F} ),
    // VPSLLQ
    instr(.VPSLLQ,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xF3),    .RVM, .ZO, .{AVX} ),
    instr(.VPSLLQ,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x73, 6), .VMI, .ZO, .{AVX} ),
    instr(.VPSLLQ,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xF3),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSLLQ,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x73, 6), .VMI, .ZO, .{AVX2} ),
    instr(.VPSLLQ,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W1,   0xF3),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLQ,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W1,   0xF3),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLQ,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W1,   0xF3),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSLLQ,     ops3(.xmm_kz, .xmm_m128_m64bcst, .imm8),evexr(.L128,._66,._0F,.W1,  0x73, 6), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLQ,     ops3(.ymm_kz, .ymm_m256_m64bcst, .imm8),evexr(.L256,._66,._0F,.W1,  0x73, 6), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSLLQ,     ops3(.zmm_kz, .zmm_m512_m64bcst, .imm8),evexr(.L512,._66,._0F,.W1,  0x73, 6), .VMI, .ZO, .{AVX512F} ),
// VPSRAW / VPSRAD / VPSRAQ
    // VPSRAW
    instr(.VPSRAW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xE1),    .RVM, .ZO, .{AVX} ),
    instr(.VPSRAW,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x71, 4), .VMI, .ZO, .{AVX} ),
    instr(.VPSRAW,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xE1),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSRAW,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x71, 4), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRAW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG,  0xE1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRAW,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.WIG,  0xE1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRAW,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.WIG,  0xE1),    .RVM, .ZO, .{AVX512BW} ),
    instr(.VPSRAW,     ops3(.xmm_kz, .xmm_m128, .imm8),        evexr(.L128,._66,._0F,.WIG, 0x71, 4), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRAW,     ops3(.ymm_kz, .ymm_m256, .imm8),        evexr(.L256,._66,._0F,.WIG, 0x71, 4), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRAW,     ops3(.zmm_kz, .zmm_m512, .imm8),        evexr(.L512,._66,._0F,.WIG, 0x71, 4), .VMI, .ZO, .{AVX512BW} ),
    // VPSRAD
    instr(.VPSRAD,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xE2),    .RVM, .ZO, .{AVX} ),
    instr(.VPSRAD,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x72, 4), .VMI, .ZO, .{AVX} ),
    instr(.VPSRAD,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xE2),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSRAD,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x72, 4), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRAD,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W0,   0xE2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAD,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W0,   0xE2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAD,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W0,   0xE2),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSRAD,     ops3(.xmm_kz, .xmm_m128_m32bcst, .imm8),evexr(.L128,._66,._0F,.W0,  0x72, 4), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAD,     ops3(.ymm_kz, .ymm_m256_m32bcst, .imm8),evexr(.L256,._66,._0F,.W0,  0x72, 4), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAD,     ops3(.zmm_kz, .zmm_m512_m32bcst, .imm8),evexr(.L512,._66,._0F,.W0,  0x72, 4), .VMI, .ZO, .{AVX512F} ),
    // VPSRAQ
    instr(.VPSRAQ,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W1,   0xE2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAQ,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W1,   0xE2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAQ,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W1,   0xE2),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSRAQ,     ops3(.xmm_kz, .xmm_m128_m64bcst, .imm8),evexr(.L128,._66,._0F,.W1,  0x72, 4), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAQ,     ops3(.ymm_kz, .ymm_m256_m64bcst, .imm8),evexr(.L256,._66,._0F,.W1,  0x72, 4), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRAQ,     ops3(.zmm_kz, .zmm_m512_m64bcst, .imm8),evexr(.L512,._66,._0F,.W1,  0x72, 4), .VMI, .ZO, .{AVX512F} ),
// VPSRLDQ
    instr(.VPSRLDQ,    ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x73, 3), .VMI, .ZO, .{AVX} ),
    instr(.VPSRLDQ,    ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x73, 3), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRLDQ,    ops3(.xmm_kz, .xmm_m128, .imm8),        evexr(.L128,._66,._0F,.WIG, 0x73, 3), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLDQ,    ops3(.ymm_kz, .ymm_m256, .imm8),        evexr(.L256,._66,._0F,.WIG, 0x73, 3), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLDQ,    ops3(.zmm_kz, .zmm_m512, .imm8),        evexr(.L512,._66,._0F,.WIG, 0x73, 3), .VMI, .ZO, .{AVX512BW} ),
// VPSRLW / VPSRLD / VPSRLQ
    // VPSRLW
    instr(.VPSRLW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xD1),    .RVM, .ZO, .{AVX} ),
    instr(.VPSRLW,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x71, 2), .VMI, .ZO, .{AVX} ),
    instr(.VPSRLW,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xD1),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSRLW,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x71, 2), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRLW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG,  0xD1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLW,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.WIG,  0xD1),    .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLW,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.WIG,  0xD1),    .RVM, .ZO, .{AVX512BW} ),
    instr(.VPSRLW,     ops3(.xmm_kz, .xmm_m128, .imm8),        evexr(.L128,._66,._0F,.WIG, 0x71, 2), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLW,     ops3(.ymm_kz, .ymm_m256, .imm8),        evexr(.L256,._66,._0F,.WIG, 0x71, 2), .VMI, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSRLW,     ops3(.zmm_kz, .zmm_m512, .imm8),        evexr(.L512,._66,._0F,.WIG, 0x71, 2), .VMI, .ZO, .{AVX512BW} ),
    // VPSRLD
    instr(.VPSRLD,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xD2),    .RVM, .ZO, .{AVX} ),
    instr(.VPSRLD,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x72, 2), .VMI, .ZO, .{AVX} ),
    instr(.VPSRLD,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xD2),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSRLD,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x72, 2), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRLD,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W0,   0xD2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLD,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W0,   0xD2),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLD,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W0,   0xD2),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSRLD,     ops3(.xmm_kz, .xmm_m128_m32bcst, .imm8),evexr(.L128,._66,._0F,.W0,  0x72, 2), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLD,     ops3(.ymm_kz, .ymm_m256_m32bcst, .imm8),evexr(.L256,._66,._0F,.W0,  0x72, 2), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLD,     ops3(.zmm_kz, .zmm_m512_m32bcst, .imm8),evexr(.L512,._66,._0F,.W0,  0x72, 2), .VMI, .ZO, .{AVX512F} ),
    // VPSRLQ
    instr(.VPSRLQ,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG,  0xD3),    .RVM, .ZO, .{AVX} ),
    instr(.VPSRLQ,     ops3(.xmml, .xmml_m128, .imm8),          vexr(.L128,._66,._0F,.WIG, 0x73, 2), .VMI, .ZO, .{AVX} ),
    instr(.VPSRLQ,     ops3(.ymml, .ymml, .xmml_m128),          vex(.L256,._66,._0F,.WIG,  0xD3),    .RVM, .ZO, .{AVX2} ),
    instr(.VPSRLQ,     ops3(.ymml, .ymml_m256, .imm8),          vexr(.L256,._66,._0F,.WIG, 0x73, 2), .VMI, .ZO, .{AVX2} ),
    instr(.VPSRLQ,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.W1,   0xD3),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLQ,     ops3(.ymm_kz, .ymm, .xmm_m128),         evex(.L256,._66,._0F,.W1,   0xD3),    .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLQ,     ops3(.zmm_kz, .zmm, .xmm_m128),         evex(.L512,._66,._0F,.W1,   0xD3),    .RVM, .ZO, .{AVX512F} ),
    instr(.VPSRLQ,     ops3(.xmm_kz, .xmm_m128_m64bcst, .imm8),evexr(.L128,._66,._0F,.W1,  0x73, 2), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLQ,     ops3(.ymm_kz, .ymm_m256_m64bcst, .imm8),evexr(.L256,._66,._0F,.W1,  0x73, 2), .VMI, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSRLQ,     ops3(.zmm_kz, .zmm_m512_m64bcst, .imm8),evexr(.L512,._66,._0F,.W1,  0x73, 2), .VMI, .ZO, .{AVX512F} ),
// VPSUBB / VPSUBW / VPSUBD
    // VPSUBB
    instr(.VPSUBB,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xF8),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBB,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xF8),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBB,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xF8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBB,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xF8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBB,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xF8),   .RVM, .ZO, .{AVX512BW} ),
    // VPSUBW
    instr(.VPSUBW,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xF9),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBW,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xF9),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBW,     ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xF9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBW,     ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xF9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBW,     ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xF9),   .RVM, .ZO, .{AVX512BW} ),
    // VPSUBD
    instr(.VPSUBD,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xFA),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBD,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xFA),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBD,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xFA),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSUBD,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xFA),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSUBD,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xFA),   .RVM, .ZO, .{AVX512F} ),
// VPSUBQ
    instr(.VPSUBQ,     ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xFB),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBQ,     ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xFB),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBQ,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xFB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSUBQ,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xFB),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPSUBQ,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xFB),   .RVM, .ZO, .{AVX512F} ),
// VPSUBSB / VPSUBSW
    instr(.VPSUBSB,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE8),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBSB,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE8),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBSB,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBSB,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBSB,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE8),   .RVM, .ZO, .{AVX512BW} ),
    //
    instr(.VPSUBSW,    ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xE9),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBSW,    ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xE9),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBSW,    ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xE9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBSW,    ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xE9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBSW,    ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xE9),   .RVM, .ZO, .{AVX512BW} ),
// VPSUBUSB / VPSUBUSW
    instr(.VPSUBUSB,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xD8),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBUSB,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xD8),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBUSB,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xD8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBUSB,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xD8),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBUSB,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xD8),   .RVM, .ZO, .{AVX512BW} ),
    //
    instr(.VPSUBUSW,   ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xD9),   .RVM, .ZO, .{AVX} ),
    instr(.VPSUBUSW,   ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xD9),   .RVM, .ZO, .{AVX2} ),
    instr(.VPSUBUSW,   ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0xD9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBUSW,   ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0xD9),   .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPSUBUSW,   ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0xD9),   .RVM, .ZO, .{AVX512BW} ),
// VPTEST
    instr(.VPTEST,     ops2(.xmml, .xmml_m128),                 vex(.L128,._66,._0F38,.WIG, 0x17), .vRM, .ZO, .{AVX} ),
    instr(.VPTEST,     ops2(.ymml, .ymml_m256),                 vex(.L256,._66,._0F38,.WIG, 0x17), .vRM, .ZO, .{AVX} ),
// VPUNPCKHBW / VPUNPCKHWD / VPUNPCKHDQ / VPUNPCKHQDQ
    // VPUNPCKHBW
    instr(.VPUNPCKHBW, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x68),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKHBW, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x68),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKHBW, ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0x68),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKHBW, ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0x68),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKHBW, ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0x68),   .RVM, .ZO,  .{AVX512BW} ),
    // VPUNPCKHWD
    instr(.VPUNPCKHWD, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x69),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKHWD, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x69),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKHWD, ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0x69),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKHWD, ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0x69),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKHWD, ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0x69),   .RVM, .ZO,  .{AVX512BW} ),
    // VPUNPCKHDQ
    instr(.VPUNPCKHDQ, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x6A),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKHDQ, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x6A),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKHDQ, ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0x6A),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKHDQ, ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0x6A),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKHDQ, ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0x6A),   .RVM, .ZO,  .{AVX512F} ),
    // VPUNPCKHQDQ
    instr(.VPUNPCKHQDQ,ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x6D),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKHQDQ,ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x6D),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKHQDQ,ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0x6D),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKHQDQ,ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0x6D),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKHQDQ,ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0x6D),   .RVM, .ZO,  .{AVX512F} ),
// VPUNPCKLBW / VPUNPCKLWD / VPUNPCKLDQ / VPUNPCKLQDQ
    // VPUNPCKLBW
    instr(.VPUNPCKLBW, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x60),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKLBW, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x60),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKLBW, ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0x60),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKLBW, ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0x60),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKLBW, ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0x60),   .RVM, .ZO,  .{AVX512BW} ),
    // VPUNPCKLWD
    instr(.VPUNPCKLWD, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x61),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKLWD, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x61),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKLWD, ops3(.xmm_kz, .xmm, .xmm_m128),         evex(.L128,._66,._0F,.WIG, 0x61),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKLWD, ops3(.ymm_kz, .ymm, .ymm_m256),         evex(.L256,._66,._0F,.WIG, 0x61),   .RVM, .ZO,  .{AVX512VL, AVX512BW} ),
    instr(.VPUNPCKLWD, ops3(.zmm_kz, .zmm, .zmm_m512),         evex(.L512,._66,._0F,.WIG, 0x61),   .RVM, .ZO,  .{AVX512BW} ),
    // VPUNPCKLDQ
    instr(.VPUNPCKLDQ, ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x62),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKLDQ, ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x62),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKLDQ, ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0x62),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKLDQ, ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0x62),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKLDQ, ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0x62),   .RVM, .ZO,  .{AVX512F} ),
    // VPUNPCKLQDQ
    instr(.VPUNPCKLQDQ,ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0x6C),   .RVM, .ZO,  .{AVX} ),
    instr(.VPUNPCKLQDQ,ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0x6C),   .RVM, .ZO,  .{AVX2} ),
    instr(.VPUNPCKLQDQ,ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0x6C),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKLQDQ,ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0x6C),   .RVM, .ZO,  .{AVX512VL, AVX512F} ),
    instr(.VPUNPCKLQDQ,ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0x6C),   .RVM, .ZO,  .{AVX512F} ),
// VPXOR
    instr(.VPXOR,      ops3(.xmml, .xmml, .xmml_m128),          vex(.L128,._66,._0F,.WIG, 0xEF),   .RVM, .ZO, .{AVX} ),
    instr(.VPXOR,      ops3(.ymml, .ymml, .ymml_m256),          vex(.L256,._66,._0F,.WIG, 0xEF),   .RVM, .ZO, .{AVX2} ),
    //
    instr(.VPXORD,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst), evex(.L128,._66,._0F,.W0,  0xEF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPXORD,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst), evex(.L256,._66,._0F,.W0,  0xEF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPXORD,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst), evex(.L512,._66,._0F,.W0,  0xEF),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VPXORQ,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst), evex(.L128,._66,._0F,.W1,  0xEF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPXORQ,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst), evex(.L256,._66,._0F,.W1,  0xEF),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPXORQ,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst), evex(.L512,._66,._0F,.W1,  0xEF),   .RVM, .ZO, .{AVX512F} ),
// VRCPPS
    instr(.VRCPPS,     ops2(.xmml, .xmml_m128),                 vex(.L128,._NP,._0F,.WIG, 0x53),   .vRM, .ZO, .{AVX} ),
    instr(.VRCPPS,     ops2(.ymml, .ymml_m256),                 vex(.L256,._NP,._0F,.WIG, 0x53),   .vRM, .ZO, .{AVX} ),
// VRCPSS
    instr(.VRCPSS,     ops3(.xmml, .xmml, .xmml_m32),           vex(.LIG,._F3,._0F,.WIG, 0x53),    .RVM, .ZO, .{AVX} ),
// VROUNDPD
    instr(.VROUNDPD,   ops3(.xmml, .xmml_m128, .imm8),          vex(.L128,._66,._0F3A,.WIG, 0x09), .vRMI,.ZO, .{AVX} ),
    instr(.VROUNDPD,   ops3(.ymml, .ymml_m256, .imm8),          vex(.L256,._66,._0F3A,.WIG, 0x09), .vRMI,.ZO, .{AVX} ),
// VROUNDPS
    instr(.VROUNDPS,   ops3(.xmml, .xmml_m128, .imm8),          vex(.L128,._66,._0F3A,.WIG, 0x08), .vRMI,.ZO, .{AVX} ),
    instr(.VROUNDPS,   ops3(.ymml, .ymml_m256, .imm8),          vex(.L256,._66,._0F3A,.WIG, 0x08), .vRMI,.ZO, .{AVX} ),
// VROUNDSD
    instr(.VROUNDSD,   ops4(.xmml, .xmml, .xmml_m64, .imm8),    vex(.LIG,._66,._0F3A,.WIG, 0x0B),  .RVMI,.ZO, .{AVX} ),
// VROUNDSS
    instr(.VROUNDSS,   ops4(.xmml, .xmml, .xmml_m32, .imm8),    vex(.LIG,._66,._0F3A,.WIG, 0x0A),  .RVMI,.ZO, .{AVX} ),
// VRSQRTPS
    instr(.VRSQRTPS,   ops2(.xmml, .xmml_m128),                 vex(.L128,._NP,._0F,.WIG, 0x52),   .vRM, .ZO, .{AVX} ),
    instr(.VRSQRTPS,   ops2(.ymml, .ymml_m256),                 vex(.L256,._NP,._0F,.WIG, 0x52),   .vRM, .ZO, .{AVX} ),
// VRSQRTSS
    instr(.VRSQRTSS,   ops3(.xmml, .xmml, .xmml_m32),           vex(.LIG,._F3,._0F,.WIG, 0x52),    .RVM, .ZO, .{AVX} ),
// VSHUFPD
    instr(.VSHUFPD,    ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._66,._0F,.WIG,0xC6), .RVMI,.ZO, .{AVX} ),
    instr(.VSHUFPD,    ops4(.ymml, .xmml, .ymml_m256, .imm8),       vex(.L256,._66,._0F,.WIG,0xC6), .RVMI,.ZO, .{AVX} ),
    instr(.VSHUFPD,    ops4(.xmm_kz,.xmm,.xmm_m128_m64bcst,.imm8), evex(.L128,._66,._0F,.W1, 0xC6), .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VSHUFPD,    ops4(.ymm_kz,.xmm,.ymm_m256_m64bcst,.imm8), evex(.L256,._66,._0F,.W1, 0xC6), .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VSHUFPD,    ops4(.zmm_kz,.xmm,.zmm_m512_m64bcst,.imm8), evex(.L512,._66,._0F,.W1, 0xC6), .RVMI,.ZO, .{AVX512F} ),
// VSHUFPS
    instr(.VSHUFPS,    ops4(.xmml, .xmml, .xmml_m128, .imm8),       vex(.L128,._NP,._0F,.WIG,0xC6), .RVMI,.ZO, .{AVX} ),
    instr(.VSHUFPS,    ops4(.ymml, .xmml, .ymml_m256, .imm8),       vex(.L256,._NP,._0F,.WIG,0xC6), .RVMI,.ZO, .{AVX} ),
    instr(.VSHUFPS,    ops4(.xmm_kz,.xmm,.xmm_m128_m32bcst,.imm8), evex(.L128,._NP,._0F,.W0, 0xC6), .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VSHUFPS,    ops4(.ymm_kz,.xmm,.ymm_m256_m32bcst,.imm8), evex(.L256,._NP,._0F,.W0, 0xC6), .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VSHUFPS,    ops4(.zmm_kz,.xmm,.zmm_m512_m32bcst,.imm8), evex(.L512,._NP,._0F,.W0, 0xC6), .RVMI,.ZO, .{AVX512F} ),
// VSQRTPD
    instr(.VSQRTPD,    ops2(.xmml, .xmml_m128),                 vex(.L128,._66,._0F,.WIG, 0x51),   .vRM, .ZO, .{AVX} ),
    instr(.VSQRTPD,    ops2(.ymml, .ymml_m256),                 vex(.L256,._66,._0F,.WIG, 0x51),   .vRM, .ZO, .{AVX} ),
    instr(.VSQRTPD,    ops2(.xmm_kz, .xmm_m128_m64bcst),       evex(.L128,._66,._0F,.W1,  0x51),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSQRTPD,    ops2(.ymm_kz, .ymm_m256_m64bcst),       evex(.L256,._66,._0F,.W1,  0x51),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSQRTPD,    ops2(.zmm_kz, .zmm_m512_m64bcst_er),    evex(.L512,._66,._0F,.W1,  0x51),   .vRM, .ZO, .{AVX512F} ),
// VSQRTPS
    instr(.VSQRTPS,    ops2(.xmml, .xmml_m128),                 vex(.L128,._NP,._0F,.WIG, 0x51),   .vRM, .ZO, .{AVX} ),
    instr(.VSQRTPS,    ops2(.ymml, .ymml_m256),                 vex(.L256,._NP,._0F,.WIG, 0x51),   .vRM, .ZO, .{AVX} ),
    instr(.VSQRTPS,    ops2(.xmm_kz, .xmm_m128_m32bcst),       evex(.L128,._NP,._0F,.W0,  0x51),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSQRTPS,    ops2(.ymm_kz, .ymm_m256_m32bcst),       evex(.L256,._NP,._0F,.W0,  0x51),   .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSQRTPS,    ops2(.zmm_kz, .zmm_m512_m32bcst_er),    evex(.L512,._NP,._0F,.W0,  0x51),   .vRM, .ZO, .{AVX512F} ),
// VSQRTSD
    instr(.VSQRTSD,    ops3(.xmml, .xmml, .xmml_m64),           vex(.LIG,._F2,._0F,.WIG, 0x51),    .RVM, .ZO, .{AVX} ),
    instr(.VSQRTSD,    ops3(.xmm_kz, .xmm, .xmm_m64_er),       evex(.LIG,._F2,._0F,.W1,  0x51),    .RVM, .ZO, .{AVX512F} ),
// VSQRTSS
    instr(.VSQRTSS,    ops3(.xmml, .xmml, .xmml_m32),           vex(.LIG,._F3,._0F,.WIG, 0x51),    .RVM, .ZO, .{AVX} ),
    instr(.VSQRTSS,    ops3(.xmm_kz, .xmm, .xmm_m32_er),       evex(.LIG,._F3,._0F,.W0,  0x51),    .RVM, .ZO, .{AVX512F} ),
// VSTMXCSR
    instr(.VSTMXCSR,   ops1(.rm_mem32),                         vexr(.LZ,._NP,._0F,.WIG, 0xAE, 3), .vM,  .ZO, .{AVX} ),
// VSUBPD
    instr(.VSUBPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x5C),   .RVM, .ZO, .{AVX} ),
    instr(.VSUBPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x5C),   .RVM, .ZO, .{AVX} ),
    instr(.VSUBPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x5C),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSUBPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x5C),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSUBPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst_er),  evex(.L512,._66,._0F,.W1,  0x5C),   .RVM, .ZO, .{AVX512F} ),
// VSUBPS
    instr(.VSUBPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x5C),   .RVM, .ZO, .{AVX} ),
    instr(.VSUBPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x5C),   .RVM, .ZO, .{AVX} ),
    instr(.VSUBPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x5C),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSUBPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x5C),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VSUBPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst_er),  evex(.L512,._NP,._0F,.W0,  0x5C),   .RVM, .ZO, .{AVX512F} ),
// VSUBSD
    instr(.VSUBSD,     ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._F2,._0F,.WIG, 0x5C),    .RVM, .ZO, .{AVX} ),
    instr(.VSUBSD,     ops3(.xmm_kz, .xmm, .xmm_m64_er),           evex(.LIG,._F2,._0F,.W1,  0x5C),    .RVM, .ZO, .{AVX512F} ),
// VSUBSS
    instr(.VSUBSS,     ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._F3,._0F,.WIG, 0x5C),    .RVM, .ZO, .{AVX} ),
    instr(.VSUBSS,     ops3(.xmm_kz, .xmm, .xmm_m32_er),           evex(.LIG,._F3,._0F,.W0,  0x5C),    .RVM, .ZO, .{AVX512F} ),
// VUCOMISD
    instr(.VUCOMISD,   ops2(.xmml, .xmml_m64),                      vex(.LIG,._66,._0F,.WIG, 0x2E),    .vRM, .ZO, .{AVX} ),
    instr(.VUCOMISD,   ops2(.xmm_kz, .xmm_m64_sae),                evex(.LIG,._66,._0F,.W1,  0x2E),    .vRM, .ZO, .{AVX512F} ),
// VUCOMISS
    instr(.VUCOMISS,   ops2(.xmml, .xmml_m32),                      vex(.LIG,._NP,._0F,.WIG, 0x2E),    .vRM, .ZO, .{AVX} ),
    instr(.VUCOMISS,   ops2(.xmm_kz, .xmm_m32_sae),                evex(.LIG,._NP,._0F,.W0,  0x2E),    .vRM, .ZO, .{AVX512F} ),
// VUNPCKHPD
    instr(.VUNPCKHPD,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x15),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKHPD,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x15),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKHPD,  ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x15),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKHPD,  ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x15),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKHPD,  ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x15),   .RVM, .ZO, .{AVX512F} ),
// VUNPCKHPS
    instr(.VUNPCKHPS,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x15),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKHPS,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x15),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKHPS,  ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x15),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKHPS,  ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x15),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKHPS,  ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x15),   .RVM, .ZO, .{AVX512F} ),
// VUNPCKLPD
    instr(.VUNPCKLPD,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x14),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKLPD,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x14),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKLPD,  ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x14),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKLPD,  ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x14),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKLPD,  ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x14),   .RVM, .ZO, .{AVX512F} ),
// VUNPCKLPS
    instr(.VUNPCKLPS,  ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x14),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKLPS,  ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x14),   .RVM, .ZO, .{AVX} ),
    instr(.VUNPCKLPS,  ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x14),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKLPS,  ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x14),   .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VUNPCKLPS,  ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x14),   .RVM, .ZO, .{AVX512F} ),
//
// Instructions V-Z
//
// VALIGND / VALIGNQ
    // VALIGND
    instr(.VALIGND,    ops4(.xmm_kz,.xmm,.xmm_m128_m32bcst,.imm8),  evex(.L128,._66,._0F3A,.W0, 0x03),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VALIGND,    ops4(.ymm_kz,.xmm,.ymm_m256_m32bcst,.imm8),  evex(.L256,._66,._0F3A,.W0, 0x03),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VALIGND,    ops4(.zmm_kz,.xmm,.zmm_m512_m32bcst,.imm8),  evex(.L512,._66,._0F3A,.W0, 0x03),  .RVMI,.ZO, .{AVX512F} ),
    // VALIGNQ
    instr(.VALIGNQ,    ops4(.xmm_kz,.xmm,.xmm_m128_m64bcst,.imm8),  evex(.L128,._66,._0F3A,.W1, 0x03),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VALIGNQ,    ops4(.ymm_kz,.xmm,.ymm_m256_m64bcst,.imm8),  evex(.L256,._66,._0F3A,.W1, 0x03),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VALIGNQ,    ops4(.zmm_kz,.xmm,.zmm_m512_m64bcst,.imm8),  evex(.L512,._66,._0F3A,.W1, 0x03),  .RVMI,.ZO, .{AVX512F} ),
// VBLENDMPD / VBLENDMPS
    // VBLENDMPD
    instr(.VBLENDMPD,  ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0x65),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBLENDMPD,  ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0x65),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBLENDMPD,  ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),      evex(.L512,._66,._0F38,.W1, 0x65),  .RVM, .ZO, .{AVX512F} ),
    // VBLENDMPS
    instr(.VBLENDMPS,  ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0x65),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBLENDMPS,  ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0x65),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBLENDMPS,  ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),      evex(.L512,._66,._0F38,.W0, 0x65),  .RVM, .ZO, .{AVX512F} ),
// VBROADCAST
    // VBROADCASTSS
    instr(.VBROADCASTSS,     ops2(.xmml, .rm_mem32),                 vex(.L128,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX} ),
    instr(.VBROADCASTSS,     ops2(.ymml, .rm_mem32),                 vex(.L256,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX} ),
    instr(.VBROADCASTSS,     ops2(.xmml, .rm_xmml),                  vex(.L128,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX2} ),
    instr(.VBROADCASTSS,     ops2(.ymml, .rm_xmml),                  vex(.L256,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX2} ),
    instr(.VBROADCASTSS,     ops2(.xmm_kz, .xmm_m32),               evex(.L128,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBROADCASTSS,     ops2(.ymm_kz, .xmm_m32),               evex(.L256,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBROADCASTSS,     ops2(.zmm_kz, .xmm_m32),               evex(.L512,._66,._0F38,.W0, 0x18),  .vRM, .ZO, .{AVX512F} ),
    // VBROADCASTSD
    instr(.VBROADCASTSD,     ops2(.ymml, .rm_mem64),                 vex(.L256,._66,._0F38,.W0, 0x19),  .vRM, .ZO, .{AVX} ),
    instr(.VBROADCASTSD,     ops2(.ymml, .rm_xmml),                  vex(.L256,._66,._0F38,.W0, 0x19),  .vRM, .ZO, .{AVX2} ),
    instr(.VBROADCASTSD,     ops2(.ymm_kz, .xmm_m64),               evex(.L256,._66,._0F38,.W1, 0x19),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBROADCASTSD,     ops2(.zmm_kz, .xmm_m64),               evex(.L512,._66,._0F38,.W1, 0x19),  .vRM, .ZO, .{AVX512F} ),
    // VBROADCASTF128
    instr(.VBROADCASTF128,   ops2(.ymml, .rm_mem128),                vex(.L256,._66,._0F38,.W0, 0x1A),  .vRM, .ZO, .{AVX} ),
    // VBROADCASTF32X2
    instr(.VBROADCASTF32X2,  ops2(.ymm_kz, .xmm_m64),               evex(.L256,._66,._0F38,.W0, 0x19),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VBROADCASTF32X2,  ops2(.zmm_kz, .xmm_m64),               evex(.L512,._66,._0F38,.W0, 0x19),  .vRM, .ZO, .{AVX512DQ} ),
    // VBROADCASTF32X4
    instr(.VBROADCASTF32X4,  ops2(.ymm_kz, .rm_mem128),             evex(.L256,._66,._0F38,.W0, 0x1A),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VBROADCASTF32X4,  ops2(.zmm_kz, .rm_mem128),             evex(.L512,._66,._0F38,.W0, 0x1A),  .vRM, .ZO, .{AVX512F} ),
    // VBROADCASTF64X2
    instr(.VBROADCASTF64X2,  ops2(.ymm_kz, .rm_mem128),             evex(.L256,._66,._0F38,.W1, 0x1A),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VBROADCASTF64X2,  ops2(.zmm_kz, .rm_mem128),             evex(.L512,._66,._0F38,.W1, 0x1A),  .vRM, .ZO, .{AVX512DQ} ),
    // VBROADCASTF32X8
    instr(.VBROADCASTF32X8,  ops2(.zmm_kz, .rm_mem256),             evex(.L512,._66,._0F38,.W0, 0x1B),  .vRM, .ZO, .{AVX512DQ} ),
    // VBROADCASTF64X4
    instr(.VBROADCASTF64X4,  ops2(.zmm_kz, .rm_mem256),             evex(.L512,._66,._0F38,.W1, 0x1B),  .vRM, .ZO, .{AVX512F} ),
// VCOMPRESSPD
    instr(.VCOMPRESSPD,      ops2(.xmm_m128_kz, .xmm),              evex(.L128,._66,._0F38,.W1, 0x8A),  .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCOMPRESSPD,      ops2(.ymm_m256_kz, .ymm),              evex(.L256,._66,._0F38,.W1, 0x8A),  .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCOMPRESSPD,      ops2(.zmm_m512_kz, .zmm),              evex(.L512,._66,._0F38,.W1, 0x8A),  .vMR, .ZO, .{AVX512F} ),
// VCOMPRESSPS
    instr(.VCOMPRESSPS,      ops2(.xmm_m128_kz, .xmm),              evex(.L128,._66,._0F38,.W0, 0x8A),  .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCOMPRESSPS,      ops2(.ymm_m256_kz, .ymm),              evex(.L256,._66,._0F38,.W0, 0x8A),  .vMR, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCOMPRESSPS,      ops2(.zmm_m512_kz, .zmm),              evex(.L512,._66,._0F38,.W0, 0x8A),  .vMR, .ZO, .{AVX512F} ),
// VCVTPD2QQ
    instr(.VCVTPD2QQ,        ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._66,._0F,.W1, 0x7B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPD2QQ,        ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._66,._0F,.W1, 0x7B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPD2QQ,        ops2(.zmm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._66,._0F,.W1, 0x7B),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTPD2UDQ
    instr(.VCVTPD2UDQ,       ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._NP,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2UDQ,       ops2(.xmm_kz, .ymm_m256_m64bcst),      evex(.L256,._NP,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPD2UDQ,       ops2(.ymm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._NP,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512F} ),
// VCVTPD2UQQ
    instr(.VCVTPD2UQQ,       ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._66,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPD2UQQ,       ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._66,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPD2UQQ,       ops2(.zmm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._66,._0F,.W1, 0x79),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTPH2PS
    instr(.VCVTPH2PS,        ops2(.xmml, .xmml_m64),                 vex(.L128,._66,._0F38,.W0, 0x13),  .vRM, .ZO, .{F16C} ),
    instr(.VCVTPH2PS,        ops2(.ymml, .xmml_m128),                vex(.L256,._66,._0F38,.W0, 0x13),  .vRM, .ZO, .{F16C} ),
    instr(.VCVTPH2PS,        ops2(.xmm_kz, .xmm_m64),               evex(.L128,._66,._0F38,.W0, 0x13),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPH2PS,        ops2(.ymm_kz, .xmm_m128),              evex(.L256,._66,._0F38,.W0, 0x13),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPH2PS,        ops2(.zmm_kz, .ymm_m256_sae),          evex(.L512,._66,._0F38,.W0, 0x13),  .vRM, .ZO, .{AVX512F} ),
// VCVTPS2PH
    instr(.VCVTPS2PH,        ops3(.xmml_m64, .xmml, .imm8),          vex(.L128,._66,._0F3A,.W0, 0x1D),  .vMRI,.ZO, .{F16C} ),
    instr(.VCVTPS2PH,        ops3(.xmml_m128, .ymml, .imm8),         vex(.L256,._66,._0F3A,.W0, 0x1D),  .vMRI,.ZO, .{F16C} ),
    instr(.VCVTPS2PH,        ops3(.xmm_m64_kz, .xmm, .imm8),        evex(.L128,._66,._0F3A,.W0, 0x1D),  .vMRI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2PH,        ops3(.xmm_m128_kz, .ymm, .imm8),       evex(.L256,._66,._0F3A,.W0, 0x1D),  .vMRI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2PH,        ops3(.ymm_m256_kz, .zmm_sae, .imm8),   evex(.L512,._66,._0F3A,.W0, 0x1D),  .vMRI,.ZO, .{AVX512F} ),
// VCVTPS2QQ
    instr(.VCVTPS2QQ,        ops2(.xmm_kz, .xmm_m64_m32bcst),       evex(.L128,._66,._0F,.W0, 0x7B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPS2QQ,        ops2(.ymm_kz, .xmm_m128_m32bcst),      evex(.L256,._66,._0F,.W0, 0x7B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPS2QQ,        ops2(.zmm_kz, .ymm_m256_m32bcst_er),   evex(.L512,._66,._0F,.W0, 0x7B),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTPS2UDQ
    instr(.VCVTPS2UDQ,       ops2(.xmm_kz, .xmm_m128_m32bcst),      evex(.L128,._NP,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2UDQ,       ops2(.ymm_kz, .ymm_m256_m32bcst),      evex(.L256,._NP,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTPS2UDQ,       ops2(.zmm_kz, .zmm_m512_m32bcst_er),   evex(.L512,._NP,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512F} ),
// VCVTPS2UQQ
    instr(.VCVTPS2UQQ,       ops2(.xmm_kz, .xmm_m64_m32bcst),       evex(.L128,._66,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPS2UQQ,       ops2(.ymm_kz, .xmm_m128_m32bcst),      evex(.L256,._66,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTPS2UQQ,       ops2(.zmm_kz, .ymm_m256_m32bcst_er),   evex(.L512,._66,._0F,.W0, 0x79),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTQQ2PD
    instr(.VCVTQQ2PD,        ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._F3,._0F,.W1, 0xE6),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTQQ2PD,        ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._F3,._0F,.W1, 0xE6),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTQQ2PD,        ops2(.zmm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._F3,._0F,.W1, 0xE6),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTQQ2PS
    instr(.VCVTQQ2PS,        ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._NP,._0F,.W1, 0x5B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTQQ2PS,        ops2(.xmm_kz, .ymm_m256_m64bcst),      evex(.L256,._NP,._0F,.W1, 0x5B),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTQQ2PS,        ops2(.ymm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._NP,._0F,.W1, 0x5B),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTSD2USI
    instr(.VCVTSD2USI,       ops2(.reg32, .xmm_m64_er),             evex(.LIG,._F2,._0F,.W0,  0x79),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTSD2USI,       ops2(.reg64, .xmm_m64_er),             evex(.LIG,._F2,._0F,.W1,  0x79),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTSS2USI
    instr(.VCVTSS2USI,       ops2(.reg32, .xmm_m32_er),             evex(.LIG,._F3,._0F,.W0,  0x79),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTSS2USI,       ops2(.reg64, .xmm_m32_er),             evex(.LIG,._F3,._0F,.W1,  0x79),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTTPD2QQ
    instr(.VCVTTPD2QQ,       ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._66,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPD2QQ,       ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._66,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPD2QQ,       ops2(.zmm_kz, .zmm_m512_m64bcst_sae),  evex(.L512,._66,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTTPD2UDQ
    instr(.VCVTTPD2UDQ,      ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._NP,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPD2UDQ,      ops2(.xmm_kz, .ymm_m256_m64bcst),      evex(.L256,._NP,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPD2UDQ,      ops2(.ymm_kz, .zmm_m512_m64bcst_sae),  evex(.L512,._NP,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512F} ),
// VCVTTPD2UQQ
    instr(.VCVTTPD2UQQ,      ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._66,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPD2UQQ,      ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._66,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPD2UQQ,      ops2(.zmm_kz, .zmm_m512_m64bcst_sae),  evex(.L512,._66,._0F,.W1, 0x78),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTTPS2QQ
    instr(.VCVTTPS2QQ,       ops2(.xmm_kz, .xmm_m64_m32bcst),       evex(.L128,._66,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPS2QQ,       ops2(.ymm_kz, .xmm_m128_m32bcst),      evex(.L256,._66,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPS2QQ,       ops2(.zmm_kz, .ymm_m256_m32bcst_sae),  evex(.L512,._66,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTTPS2UDQ
    instr(.VCVTTPS2UDQ,      ops2(.xmm_kz, .xmm_m128_m32bcst),      evex(.L128,._NP,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPS2UDQ,      ops2(.ymm_kz, .ymm_m256_m32bcst),      evex(.L256,._NP,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTTPS2UDQ,      ops2(.zmm_kz, .zmm_m512_m32bcst_sae),  evex(.L512,._NP,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512F} ),
// VCVTTPS2UQQ
    instr(.VCVTTPS2UQQ,      ops2(.xmm_kz, .xmm_m64_m32bcst),       evex(.L128,._66,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPS2UQQ,      ops2(.ymm_kz, .xmm_m128_m32bcst),      evex(.L256,._66,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTTPS2UQQ,      ops2(.zmm_kz, .ymm_m256_m32bcst_sae),  evex(.L512,._66,._0F,.W0, 0x78),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTTSD2USI
    instr(.VCVTTSD2USI,      ops2(.reg32, .xmm_m64_sae),            evex(.LIG,._F2,._0F,.W0,  0x78),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTTSD2USI,      ops2(.reg64, .xmm_m64_sae),            evex(.LIG,._F2,._0F,.W1,  0x78),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTTSS2USI
    instr(.VCVTTSS2USI,      ops2(.reg32, .xmm_m32_sae),            evex(.LIG,._F3,._0F,.W0,  0x78),    .vRM, .ZO, .{AVX512F} ),
    instr(.VCVTTSS2USI,      ops2(.reg64, .xmm_m32_sae),            evex(.LIG,._F3,._0F,.W1,  0x78),    .vRM, .ZO, .{AVX512F, No32} ),
// VCVTUDQ2PD
    instr(.VCVTUDQ2PD,       ops2(.xmm_kz, .xmm_m64_m32bcst),       evex(.L128,._F3,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTUDQ2PD,       ops2(.ymm_kz, .xmm_m128_m32bcst),      evex(.L256,._F3,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTUDQ2PD,       ops2(.zmm_kz, .ymm_m256_m32bcst),      evex(.L512,._F3,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512F} ),
// VCVTUDQ2PS
    instr(.VCVTUDQ2PS,       ops2(.xmm_kz, .xmm_m128_m32bcst),      evex(.L128,._F2,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTUDQ2PS,       ops2(.ymm_kz, .ymm_m256_m32bcst),      evex(.L256,._F2,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VCVTUDQ2PS,       ops2(.zmm_kz, .zmm_m512_m32bcst_er),   evex(.L512,._F2,._0F,.W0, 0x7A),    .vRM, .ZO, .{AVX512F} ),
// VCVTUQQ2PD
    instr(.VCVTUQQ2PD,       ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._F3,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTUQQ2PD,       ops2(.ymm_kz, .ymm_m256_m64bcst),      evex(.L256,._F3,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTUQQ2PD,       ops2(.zmm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._F3,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTUQQ2PS
    instr(.VCVTUQQ2PS,       ops2(.xmm_kz, .xmm_m128_m64bcst),      evex(.L128,._F2,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTUQQ2PS,       ops2(.xmm_kz, .ymm_m256_m64bcst),      evex(.L256,._F2,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VCVTUQQ2PS,       ops2(.ymm_kz, .zmm_m512_m64bcst_er),   evex(.L512,._F2,._0F,.W1, 0x7A),    .vRM, .ZO, .{AVX512DQ} ),
// VCVTUSI2SD
    instr(.VCVTUSI2SD,       ops3(.xmm, .xmm, .rm32),               evex(.LIG,._F2,._0F,.W0,  0x7B),    .RVM, .ZO, .{AVX512F} ),
    instr(.VCVTUSI2SD,       ops3(.xmm, .xmm, .rm64_er),            evex(.LIG,._F2,._0F,.W1,  0x7B),    .RVM, .ZO, .{AVX512F, No32} ),
// VCVTUSI2SS
    instr(.VCVTUSI2SS,       ops3(.xmm, .xmm, .rm32_er),            evex(.LIG,._F3,._0F,.W0,  0x7B),    .RVM, .ZO, .{AVX512F} ),
    instr(.VCVTUSI2SS,       ops3(.xmm, .xmm, .rm64_er),            evex(.LIG,._F3,._0F,.W1,  0x7B),    .RVM, .ZO, .{AVX512F, No32} ),
// VDBPSADBW
    instr(.VDBPSADBW,        ops4(.xmm_kz,.xmm,.xmm_m128,.imm8),    evex(.L128,._66,._0F3A,.W0, 0x42),  .RVMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VDBPSADBW,        ops4(.ymm_kz,.ymm,.ymm_m256,.imm8),    evex(.L256,._66,._0F3A,.W0, 0x42),  .RVMI,.ZO, .{AVX512VL, AVX512BW} ),
    instr(.VDBPSADBW,        ops4(.zmm_kz,.zmm,.zmm_m512,.imm8),    evex(.L512,._66,._0F3A,.W0, 0x42),  .RVMI,.ZO, .{AVX512BW} ),
// VEXPANDPD
    instr(.VEXPANDPD,       ops2(.xmm_kz, .xmm_m128),               evex(.L128,._66,._0F38,.W1, 0x88),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXPANDPD,       ops2(.ymm_kz, .ymm_m256),               evex(.L256,._66,._0F38,.W1, 0x88),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXPANDPD,       ops2(.zmm_kz, .zmm_m512),               evex(.L512,._66,._0F38,.W1, 0x88),  .vRM, .ZO, .{AVX512F} ),
// VEXPANDPS
    instr(.VEXPANDPS,       ops2(.xmm_kz, .xmm_m128),               evex(.L128,._66,._0F38,.W0, 0x88),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXPANDPS,       ops2(.ymm_kz, .ymm_m256),               evex(.L256,._66,._0F38,.W0, 0x88),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXPANDPS,       ops2(.zmm_kz, .zmm_m512),               evex(.L512,._66,._0F38,.W0, 0x88),  .vRM, .ZO, .{AVX512F} ),
// VEXTRACTF (128, F32x4, 64x2, 32x8, 64x4)
    // VEXTRACTF128
    instr(.VEXTRACTF128,   ops3(.xmml_m128, .ymml, .imm8),           vex(.L256,._66,._0F3A,.W0, 0x19),  .vMRI,.ZO, .{AVX} ),
    // VEXTRACTF32X4
    instr(.VEXTRACTF32X4,  ops3(.xmm_m128_kz, .ymm, .imm8),         evex(.L256,._66,._0F3A,.W0, 0x19),  .vMRI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXTRACTF32X4,  ops3(.xmm_m128_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W0, 0x19),  .vMRI,.ZO, .{AVX512F} ),
    // VEXTRACTF64X2
    instr(.VEXTRACTF64X2,  ops3(.xmm_m128_kz, .ymm, .imm8),         evex(.L256,._66,._0F3A,.W1, 0x19),  .vMRI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VEXTRACTF64X2,  ops3(.xmm_m128_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W1, 0x19),  .vMRI,.ZO, .{AVX512DQ} ),
    // VEXTRACTF32X8
    instr(.VEXTRACTF32X8,  ops3(.ymm_m256_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W0, 0x1B),  .vMRI,.ZO, .{AVX512DQ} ),
    // VEXTRACTF64X4
    instr(.VEXTRACTF64X4,  ops3(.ymm_m256_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W1, 0x1B),  .vMRI,.ZO, .{AVX512F} ),
// VEXTRACTI (128, F32x4, 64x2, 32x8, 64x4)
    // VEXTRACTI128
    instr(.VEXTRACTI128,   ops3(.xmml_m128, .ymml, .imm8),           vex(.L256,._66,._0F3A,.W0, 0x39),  .vMRI,.ZO, .{AVX2} ),
    // VEXTRACTI32X4
    instr(.VEXTRACTI32X4,  ops3(.xmm_m128_kz, .ymm, .imm8),         evex(.L256,._66,._0F3A,.W0, 0x39),  .vMRI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VEXTRACTI32X4,  ops3(.xmm_m128_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W0, 0x39),  .vMRI,.ZO, .{AVX512F} ),
    // VEXTRACTI64X2
    instr(.VEXTRACTI64X2,  ops3(.xmm_m128_kz, .ymm, .imm8),         evex(.L256,._66,._0F3A,.W1, 0x39),  .vMRI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VEXTRACTI64X2,  ops3(.xmm_m128_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W1, 0x39),  .vMRI,.ZO, .{AVX512DQ} ),
    // VEXTRACTI32X8
    instr(.VEXTRACTI32X8,  ops3(.ymm_m256_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W0, 0x3B),  .vMRI,.ZO, .{AVX512DQ} ),
    // VEXTRACTI64X4
    instr(.VEXTRACTI64X4,  ops3(.ymm_m256_kz, .zmm, .imm8),         evex(.L512,._66,._0F3A,.W1, 0x3B),  .vMRI,.ZO, .{AVX512F} ),
// VFIXUPIMMPD
    instr(.VFIXUPIMMPD, ops4(.xmm_kz,.xmm,.xmm_m128_m64bcst,.imm8),     evex(.L128,._66,._0F3A,.W1, 0x54),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VFIXUPIMMPD, ops4(.ymm_kz,.ymm,.ymm_m256_m64bcst,.imm8),     evex(.L256,._66,._0F3A,.W1, 0x54),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VFIXUPIMMPD, ops4(.zmm_kz,.ymm,.zmm_m512_m64bcst_sae,.imm8), evex(.L512,._66,._0F3A,.W1, 0x54),  .RVMI,.ZO, .{AVX512F} ),
// VFIXUPIMMPS
    instr(.VFIXUPIMMPS, ops4(.xmm_kz,.xmm,.xmm_m128_m32bcst,.imm8),     evex(.L128,._66,._0F3A,.W0, 0x54),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VFIXUPIMMPS, ops4(.ymm_kz,.ymm,.ymm_m256_m32bcst,.imm8),     evex(.L256,._66,._0F3A,.W0, 0x54),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VFIXUPIMMPS, ops4(.zmm_kz,.ymm,.zmm_m512_m32bcst_sae,.imm8), evex(.L512,._66,._0F3A,.W0, 0x54),  .RVMI,.ZO, .{AVX512F} ),
// VFIXUPIMMSD
    instr(.VFIXUPIMMSD, ops4(.xmm_kz,.xmm,.xmm_m64_sae,.imm8),          evex(.LIG,._66,._0F3A,.W1, 0x55),   .RVMI,.ZO, .{AVX512VL, AVX512F} ),
// VFIXUPIMMSS
    instr(.VFIXUPIMMSS, ops4(.xmm_kz,.xmm,.xmm_m32_sae,.imm8),          evex(.LIG,._66,._0F3A,.W0, 0x55),   .RVMI,.ZO, .{AVX512VL, AVX512F} ),
// VFMADD132PD / VFMADD213PD / VFMADD231PD
    instr(.VFMADD132PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0x98),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0x98),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0x98),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0x98),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0x98),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD213PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0xA8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0xA8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0xA8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0xA8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0xA8),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD231PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0xB8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0xB8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0xB8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0xB8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0xB8),  .RVM, .ZO, .{AVX512F} ),
// VFMADD132PS / VFMADD213PS / VFMADD231PS
    instr(.VFMADD132PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0x98),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0x98),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0x98),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0x98),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0x98),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD213PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0xA8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0xA8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0xA8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0xA8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0xA8),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD231PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0xB8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0xB8),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0xB8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0xB8),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADD231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0xB8),  .RVM, .ZO, .{AVX512F} ),
// VFMADD132SD / VFMADD213SD / VFMADD231SD
    instr(.VFMADD132SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0x99),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0x99),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD213SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0xA9),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0xA9),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD231SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0xB9),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0xB9),   .RVM, .ZO, .{AVX512F} ),
// VFMADD132SS / VFMADD213SS / VFMADD231SS
    instr(.VFMADD132SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0x99),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD132SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0x99),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD213SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0xA9),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD213SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0xA9),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADD231SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0xB9),   .RVM, .ZO, .{FMA} ),
    instr(.VFMADD231SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0xB9),   .RVM, .ZO, .{AVX512F} ),
// VFMADDSUB132PD / VFMADDSUB213PD / VFMADDSUB231PD
    instr(.VFMADDSUB132PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0x96),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB132PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0x96),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0x96),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0x96),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0x96),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADDSUB213PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0xA6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB213PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0xA6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0xA6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0xA6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0xA6),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADDSUB231PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0xB6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB231PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0xB6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0xB6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0xB6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0xB6),  .RVM, .ZO, .{AVX512F} ),
// VFMADDSUB132PS / VFMADDSUB213PS / VFMADDSUB231PS
    instr(.VFMADDSUB132PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0x96),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB132PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0x96),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0x96),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0x96),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0x96),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADDSUB213PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0xA6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB213PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0xA6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0xA6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0xA6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0xA6),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMADDSUB231PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0xB6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB231PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0xB6),  .RVM, .ZO, .{FMA} ),
    instr(.VFMADDSUB231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0xB6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0xB6),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMADDSUB231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0xB6),  .RVM, .ZO, .{AVX512F} ),
// VFMSUBADD132PD / VFMSUBADD213PD / VFMSUBADD231PD
    instr(.VFMSUBADD132PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0x97),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD132PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0x97),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0x97),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0x97),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0x97),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUBADD213PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0xA7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD213PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0xA7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0xA7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0xA7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0xA7),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUBADD231PD, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W1, 0xB7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD231PD, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W1, 0xB7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),    evex(.L128,._66,._0F38,.W1, 0xB7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),    evex(.L256,._66,._0F38,.W1, 0xB7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er), evex(.L512,._66,._0F38,.W1, 0xB7),  .RVM, .ZO, .{AVX512F} ),
// VFMSUBADD132PS / VFMSUBADD213PS / VFMSUBADD231PS
    instr(.VFMSUBADD132PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0x97),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD132PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0x97),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0x97),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0x97),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0x97),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUBADD213PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0xA7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD213PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0xA7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0xA7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0xA7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0xA7),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUBADD231PS, ops3(.xmml, .xmml, .xmml_m128),           vex(.L128,._66,._0F38,.W0, 0xB7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD231PS, ops3(.ymml, .ymml, .ymml_m256),           vex(.L256,._66,._0F38,.W0, 0xB7),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUBADD231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),    evex(.L128,._66,._0F38,.W0, 0xB7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),    evex(.L256,._66,._0F38,.W0, 0xB7),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUBADD231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er), evex(.L512,._66,._0F38,.W0, 0xB7),  .RVM, .ZO, .{AVX512F} ),
// VFMSUB132PD / VFMSUB213PD / VFMSUB231PD
    instr(.VFMSUB132PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0x9A),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0x9A),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0x9A),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0x9A),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0x9A),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB213PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0xAA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0xAA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0xAA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0xAA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0xAA),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB231PD, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W1, 0xBA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231PD, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W1, 0xBA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),       evex(.L128,._66,._0F38,.W1, 0xBA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),       evex(.L256,._66,._0F38,.W1, 0xBA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),    evex(.L512,._66,._0F38,.W1, 0xBA),  .RVM, .ZO, .{AVX512F} ),
// VFMSUB132PS / VFMSUB213PS / VFMSUB231PS
    instr(.VFMSUB132PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0x9A),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0x9A),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0x9A),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0x9A),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0x9A),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB213PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0xAA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0xAA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0xAA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0xAA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0xAA),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB231PS, ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F38,.W0, 0xBA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231PS, ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F38,.W0, 0xBA),  .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),       evex(.L128,._66,._0F38,.W0, 0xBA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),       evex(.L256,._66,._0F38,.W0, 0xBA),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFMSUB231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),    evex(.L512,._66,._0F38,.W0, 0xBA),  .RVM, .ZO, .{AVX512F} ),
// VFMSUB132SD / VFMSUB213SD / VFMSUB231SD
    instr(.VFMSUB132SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0x9B),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0x9B),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB213SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0xAB),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0xAB),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB231SD, ops3(.xmml, .xmml, .xmml_m64),               vex(.LIG,._66,._0F38,.W1, 0xBB),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),             evex(.LIG,._66,._0F38,.W1, 0xBB),   .RVM, .ZO, .{AVX512F} ),
// VFMSUB132SS / VFMSUB213SS / VFMSUB231SS
    instr(.VFMSUB132SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0x9B),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB132SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0x9B),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB213SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0xAB),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB213SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0xAB),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFMSUB231SS, ops3(.xmml, .xmml, .xmml_m32),               vex(.LIG,._66,._0F38,.W0, 0xBB),   .RVM, .ZO, .{FMA} ),
    instr(.VFMSUB231SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),             evex(.LIG,._66,._0F38,.W0, 0xBB),   .RVM, .ZO, .{AVX512F} ),
// VFNMADD132PD / VFNMADD213PD / VFNMADD231PD
    instr(.VFNMADD132PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0x9C),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0x9C),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0x9C),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0x9C),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0x9C),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD213PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0xAC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0xAC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0xAC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0xAC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0xAC),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD231PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0xBC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0xBC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0xBC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0xBC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0xBC),  .RVM, .ZO, .{AVX512F} ),
// VFNMADD132PS / VFNMADD213PS / VFNMADD231PS
    instr(.VFNMADD132PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0x9C),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0x9C),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0x9C),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0x9C),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0x9C),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD213PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0xAC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0xAC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0xAC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0xAC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0xAC),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD231PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0xBC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0xBC),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0xBC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0xBC),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMADD231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0xBC),  .RVM, .ZO, .{AVX512F} ),
// VFNMADD132SD / VFNMADD213SD / VFNMADD231SD
    instr(.VFNMADD132SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0x9D),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0x9D),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD213SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0xAD),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0xAD),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD231SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0xBD),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0xBD),   .RVM, .ZO, .{AVX512F} ),
// VFNMADD132SS / VFNMADD213SS / VFNMADD231SS
    instr(.VFNMADD132SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0x9D),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD132SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0x9D),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD213SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0xAD),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD213SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0xAD),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMADD231SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0xBD),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMADD231SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0xBD),   .RVM, .ZO, .{AVX512F} ),
// VFNMSUB132PD / VFNMSUB213PD / VFNMSUB231PD
    instr(.VFNMSUB132PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0x9E),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0x9E),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0x9E),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB132PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0x9E),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB132PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0x9E),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB213PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0xAE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0xAE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0xAE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB213PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0xAE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB213PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0xAE),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB231PD, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W1, 0xBE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231PD, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W1, 0xBE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231PD, ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),      evex(.L128,._66,._0F38,.W1, 0xBE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB231PD, ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),      evex(.L256,._66,._0F38,.W1, 0xBE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB231PD, ops3(.zmm_kz,.ymm,.zmm_m512_m64bcst_er),   evex(.L512,._66,._0F38,.W1, 0xBE),  .RVM, .ZO, .{AVX512F} ),
// VFNMSUB132PS / VFNMSUB213PS / VFNMSUB231PS
    instr(.VFNMSUB132PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0x9E),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0x9E),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0x9E),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB132PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0x9E),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB132PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0x9E),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB213PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0xAE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0xAE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0xAE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB213PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0xAE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB213PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0xAE),  .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB231PS, ops3(.xmml, .xmml, .xmml_m128),             vex(.L128,._66,._0F38,.W0, 0xBE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231PS, ops3(.ymml, .ymml, .ymml_m256),             vex(.L256,._66,._0F38,.W0, 0xBE),  .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231PS, ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),      evex(.L128,._66,._0F38,.W0, 0xBE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB231PS, ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),      evex(.L256,._66,._0F38,.W0, 0xBE),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VFNMSUB231PS, ops3(.zmm_kz,.ymm,.zmm_m512_m32bcst_er),   evex(.L512,._66,._0F38,.W0, 0xBE),  .RVM, .ZO, .{AVX512F} ),
// VFNMSUB132SD / VFNMSUB213SD / VFNMSUB231SD
    instr(.VFNMSUB132SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0x9F),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0x9F),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB213SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0xAF),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0xAF),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB231SD, ops3(.xmml, .xmml, .xmml_m64),              vex(.LIG,._66,._0F38,.W1, 0xBF),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231SD, ops3(.xmm_kz,.xmm,.xmm_m64_er),            evex(.LIG,._66,._0F38,.W1, 0xBF),   .RVM, .ZO, .{AVX512F} ),
// VFNMSUB132SS / VFNMSUB213SS / VFNMSUB231SS
    instr(.VFNMSUB132SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0x9F),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB132SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0x9F),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB213SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0xAF),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB213SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0xAF),   .RVM, .ZO, .{AVX512F} ),
    //
    instr(.VFNMSUB231SS, ops3(.xmml, .xmml, .xmml_m32),              vex(.LIG,._66,._0F38,.W0, 0xBF),   .RVM, .ZO, .{FMA} ),
    instr(.VFNMSUB231SS, ops3(.xmm_kz,.xmm,.xmm_m32_er),            evex(.LIG,._66,._0F38,.W0, 0xBF),   .RVM, .ZO, .{AVX512F} ),
// VFPCLASSPD
    instr(.VFPCLASSPD,   ops3(.reg_k_k,.xmm_m128_m64bcst,.imm8),    evex(.L128,._66,._0F3A,.W1, 0x66),  .vRMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VFPCLASSPD,   ops3(.reg_k_k,.ymm_m256_m64bcst,.imm8),    evex(.L256,._66,._0F3A,.W1, 0x66),  .vRMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VFPCLASSPD,   ops3(.reg_k_k,.zmm_m512_m64bcst,.imm8),    evex(.L512,._66,._0F3A,.W1, 0x66),  .vRMI,.ZO, .{AVX512DQ} ),
// VFPCLASSPS
    instr(.VFPCLASSPS,   ops3(.reg_k_k,.xmm_m128_m32bcst,.imm8),    evex(.L128,._66,._0F3A,.W0, 0x66),  .vRMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VFPCLASSPS,   ops3(.reg_k_k,.ymm_m256_m32bcst,.imm8),    evex(.L256,._66,._0F3A,.W0, 0x66),  .vRMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VFPCLASSPS,   ops3(.reg_k_k,.zmm_m512_m32bcst,.imm8),    evex(.L512,._66,._0F3A,.W0, 0x66),  .vRMI,.ZO, .{AVX512DQ} ),
// VFPCLASSSD
    instr(.VFPCLASSSD,   ops3(.reg_k_k,.xmm_m64,.imm8),             evex(.LIG,._66,._0F3A,.W1, 0x67),   .vRMI,.ZO, .{AVX512DQ} ),
// VFPCLASSSS
    instr(.VFPCLASSSS,   ops3(.reg_k_k,.xmm_m32,.imm8),             evex(.LIG,._66,._0F3A,.W0, 0x67),   .vRMI,.ZO, .{AVX512DQ} ),
// VGATHERDPD / VGATHERQPD
    instr(.VGATHERDPD,   ops3(.xmml, .vm32xl, .xmml),                vex(.L128,._66,._0F38,.W1, 0x92),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERDPD,   ops3(.ymml, .vm32xl, .ymml),                vex(.L256,._66,._0F38,.W1, 0x92),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERDPD,   ops2(.xmm_kz, .vm32x),                     evex(.L128,._66,._0F38,.W1, 0x92),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERDPD,   ops2(.ymm_kz, .vm32x),                     evex(.L256,._66,._0F38,.W1, 0x92),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERDPD,   ops2(.zmm_kz, .vm32y),                     evex(.L512,._66,._0F38,.W1, 0x92),  .RMV, .ZO, .{AVX512F} ),
    //
    instr(.VGATHERQPD,   ops3(.xmml, .vm64xl, .xmml),                vex(.L128,._66,._0F38,.W1, 0x93),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERQPD,   ops3(.ymml, .vm64yl, .ymml),                vex(.L256,._66,._0F38,.W1, 0x93),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERQPD,   ops2(.xmm_kz, .vm64x),                     evex(.L128,._66,._0F38,.W1, 0x93),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERQPD,   ops2(.ymm_kz, .vm64y),                     evex(.L256,._66,._0F38,.W1, 0x93),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERQPD,   ops2(.zmm_kz, .vm64z),                     evex(.L512,._66,._0F38,.W1, 0x93),  .RMV, .ZO, .{AVX512F} ),
// VGATHERDPS / VGATHERQPS
    instr(.VGATHERDPS,   ops3(.xmml, .vm32xl, .xmml),                vex(.L128,._66,._0F38,.W0, 0x92),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERDPS,   ops3(.ymml, .vm32yl, .ymml),                vex(.L256,._66,._0F38,.W0, 0x92),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERDPS,   ops2(.xmm_kz, .vm32x),                     evex(.L128,._66,._0F38,.W0, 0x92),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERDPS,   ops2(.ymm_kz, .vm32y),                     evex(.L256,._66,._0F38,.W0, 0x92),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERDPS,   ops2(.zmm_kz, .vm32z),                     evex(.L512,._66,._0F38,.W0, 0x92),  .RMV, .ZO, .{AVX512F} ),
    //
    instr(.VGATHERQPS,   ops3(.xmml, .vm64xl, .xmml),                vex(.L128,._66,._0F38,.W0, 0x93),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERQPS,   ops3(.xmml, .vm64yl, .xmml),                vex(.L256,._66,._0F38,.W0, 0x93),  .RMV, .ZO, .{AVX2} ),
    instr(.VGATHERQPS,   ops2(.xmm_kz, .vm64x),                     evex(.L128,._66,._0F38,.W0, 0x93),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERQPS,   ops2(.xmm_kz, .vm64y),                     evex(.L256,._66,._0F38,.W0, 0x93),  .RMV, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGATHERQPS,   ops2(.ymm_kz, .vm64z),                     evex(.L512,._66,._0F38,.W0, 0x93),  .RMV, .ZO, .{AVX512F} ),
// VGETEXPPD
    instr(.VGETEXPPD,    ops2(.xmm_kz, .xmm_m128_m64bcst),          evex(.L128,._66,._0F38,.W1, 0x42),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETEXPPD,    ops2(.ymm_kz, .ymm_m256_m64bcst),          evex(.L256,._66,._0F38,.W1, 0x42),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETEXPPD,    ops2(.zmm_kz, .zmm_m512_m64bcst_sae),      evex(.L512,._66,._0F38,.W1, 0x42),  .vRM, .ZO, .{AVX512F} ),
// VGETEXPPS
    instr(.VGETEXPPS,    ops2(.xmm_kz, .xmm_m128_m32bcst),          evex(.L128,._66,._0F38,.W0, 0x42),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETEXPPS,    ops2(.ymm_kz, .ymm_m256_m32bcst),          evex(.L256,._66,._0F38,.W0, 0x42),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETEXPPS,    ops2(.zmm_kz, .zmm_m512_m32bcst_sae),      evex(.L512,._66,._0F38,.W0, 0x42),  .vRM, .ZO, .{AVX512F} ),
// VGETEXPSD
    instr(.VGETEXPSD,    ops3(.xmm_kz, .xmm, .xmm_m64_sae),         evex(.LIG,._66,._0F38,.W1,  0x43),  .RVM, .ZO, .{AVX512F} ),
// VGETEXPSS
    instr(.VGETEXPSS,    ops3(.xmm_kz, .xmm, .xmm_m32_sae),         evex(.LIG,._66,._0F38,.W0,  0x43),  .RVM, .ZO, .{AVX512F} ),
// VGETMANTPD
    instr(.VGETMANTPD,   ops3(.xmm_kz,.xmm_m128_m64bcst,.imm8),     evex(.L128,._66,._0F3A,.W1, 0x26),  .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETMANTPD,   ops3(.ymm_kz,.ymm_m256_m64bcst,.imm8),     evex(.L256,._66,._0F3A,.W1, 0x26),  .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETMANTPD,   ops3(.zmm_kz,.zmm_m512_m64bcst_sae,.imm8), evex(.L512,._66,._0F3A,.W1, 0x26),  .vRMI,.ZO, .{AVX512F} ),
// VGETMANTPS
    instr(.VGETMANTPS,   ops3(.xmm_kz,.xmm_m128_m32bcst,.imm8),     evex(.L128,._66,._0F3A,.W0, 0x26),  .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETMANTPS,   ops3(.ymm_kz,.ymm_m256_m32bcst,.imm8),     evex(.L256,._66,._0F3A,.W0, 0x26),  .vRMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VGETMANTPS,   ops3(.zmm_kz,.zmm_m512_m32bcst_sae,.imm8), evex(.L512,._66,._0F3A,.W0, 0x26),  .vRMI,.ZO, .{AVX512F} ),
// VGETMANTSD
    instr(.VGETMANTSD,   ops4(.xmm_kz,.xmm,.xmm_m64_sae,.imm8),     evex(.LIG,._66,._0F3A,.W1,  0x27),  .RVMI,.ZO, .{AVX512F} ),
// VGETMANTSS
    instr(.VGETMANTSS,   ops4(.xmm_kz,.xmm,.xmm_m32_sae,.imm8),     evex(.LIG,._66,._0F3A,.W0,  0x27),  .RVMI,.ZO, .{AVX512F} ),
// VINSERTF (128, F32x4, 64x2, 32x8, 64x4)
    instr(.VINSERTF128,   ops4(.ymml,.ymml,.xmml_m128,.imm8),        vex(.L256,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX} ),
    // VINSERTF32X4
    instr(.VINSERTF32X4,  ops4(.ymm_kz,.ymm,.xmm_m128,.imm8),       evex(.L256,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VINSERTF32X4,  ops4(.zmm_kz,.zmm,.xmm_m128,.imm8),       evex(.L512,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX512F} ),
    // VINSERTF64X2
    instr(.VINSERTF64X2,  ops4(.ymm_kz,.ymm,.xmm_m128,.imm8),       evex(.L256,._66,._0F3A,.W1, 0x18),  .RVMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VINSERTF64X2,  ops4(.zmm_kz,.zmm,.xmm_m128,.imm8),       evex(.L512,._66,._0F3A,.W1, 0x18),  .RVMI,.ZO, .{AVX512DQ} ),
    // VINSERTF32X8
    instr(.VINSERTF32X8,  ops4(.zmm_kz,.zmm,.ymm_m256,.imm8),       evex(.L512,._66,._0F3A,.W0, 0x1A),  .RVMI,.ZO, .{AVX512DQ} ),
    // VINSERTF64X4
    instr(.VINSERTF64X4,  ops4(.zmm_kz,.zmm,.ymm_m256,.imm8),       evex(.L512,._66,._0F3A,.W1, 0x1A),  .RVMI,.ZO, .{AVX512F} ),
// VINSERTI (128, F32x4, 64x2, 32x8, 64x4)
    instr(.VINSERTI128,   ops4(.ymml,.ymml,.xmml_m128,.imm8),        vex(.L256,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX} ),
    // VINSERTI32X4
    instr(.VINSERTI32X4,  ops4(.ymm_kz,.ymm,.xmm_m128,.imm8),       evex(.L256,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX512VL, AVX512F} ),
    instr(.VINSERTI32X4,  ops4(.zmm_kz,.zmm,.xmm_m128,.imm8),       evex(.L512,._66,._0F3A,.W0, 0x18),  .RVMI,.ZO, .{AVX512F} ),
    // VINSERTI64X2
    instr(.VINSERTI64X2,  ops4(.ymm_kz,.ymm,.xmm_m128,.imm8),       evex(.L256,._66,._0F3A,.W1, 0x18),  .RVMI,.ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VINSERTI64X2,  ops4(.zmm_kz,.zmm,.xmm_m128,.imm8),       evex(.L512,._66,._0F3A,.W1, 0x18),  .RVMI,.ZO, .{AVX512DQ} ),
    // VINSERTI32X8
    instr(.VINSERTI32X8,  ops4(.zmm_kz,.zmm,.ymm_m256,.imm8),       evex(.L512,._66,._0F3A,.W0, 0x1A),  .RVMI,.ZO, .{AVX512DQ} ),
    // VINSERTI64X4
    instr(.VINSERTI64X4,  ops4(.zmm_kz,.zmm,.ymm_m256,.imm8),       evex(.L512,._66,._0F3A,.W1, 0x1A),  .RVMI,.ZO, .{AVX512F} ),
// VMASKMOV
    // VMASKMOVPD
    instr(.VMASKMOVPD,    ops3(.xmml,.xmml,.rm_mem128),              vex(.L128,._66,._0F38,.W0, 0x2D),  .RVM, .ZO, .{AVX} ),
    instr(.VMASKMOVPD,    ops3(.ymml,.ymml,.rm_mem256),              vex(.L256,._66,._0F38,.W0, 0x2D),  .RVM, .ZO, .{AVX} ),
    instr(.VMASKMOVPD,    ops3(.rm_mem128,.xmml,.xmml),              vex(.L128,._66,._0F38,.W0, 0x2F),  .MVR, .ZO, .{AVX} ),
    instr(.VMASKMOVPD,    ops3(.rm_mem256,.ymml,.ymml),              vex(.L256,._66,._0F38,.W0, 0x2F),  .MVR, .ZO, .{AVX} ),
    // VMASKMOVPS
    instr(.VMASKMOVPS,    ops3(.xmml,.xmml,.rm_mem128),              vex(.L128,._66,._0F38,.W0, 0x2C),  .RVM, .ZO, .{AVX} ),
    instr(.VMASKMOVPS,    ops3(.ymml,.ymml,.rm_mem256),              vex(.L256,._66,._0F38,.W0, 0x2C),  .RVM, .ZO, .{AVX} ),
    instr(.VMASKMOVPS,    ops3(.rm_mem128,.xmml,.xmml),              vex(.L128,._66,._0F38,.W0, 0x2E),  .MVR, .ZO, .{AVX} ),
    instr(.VMASKMOVPS,    ops3(.rm_mem256,.ymml,.ymml),              vex(.L256,._66,._0F38,.W0, 0x2E),  .MVR, .ZO, .{AVX} ),
// VPBLENDD
    instr(.VPBLENDD,      ops4(.xmml,.xmml,.xmml_m128,.imm8),        vex(.L128,._66,._0F3A,.W0, 0x02),  .RVMI,.ZO, .{AVX2} ),
    instr(.VPBLENDD,      ops4(.ymml,.ymml,.ymml_m256,.imm8),        vex(.L256,._66,._0F3A,.W0, 0x02),  .RVMI,.ZO, .{AVX2} ),
// VPBLENDMB / VPBLENDMW
    // VPBLENDMB
    instr(.VPBLENDMB,     ops3(.xmm_kz, .xmm, .xmm_m128),           evex(.L128,._66,._0F38,.W0, 0x66),  .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBLENDMB,     ops3(.ymm_kz, .ymm, .ymm_m256),           evex(.L256,._66,._0F38,.W0, 0x66),  .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBLENDMB,     ops3(.zmm_kz, .zmm, .zmm_m512),           evex(.L512,._66,._0F38,.W0, 0x66),  .RVM, .ZO, .{AVX512BW} ),
    // VPBLENDMW
    instr(.VPBLENDMW,     ops3(.xmm_kz, .xmm, .xmm_m128),           evex(.L128,._66,._0F38,.W1, 0x66),  .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBLENDMW,     ops3(.ymm_kz, .ymm, .ymm_m256),           evex(.L256,._66,._0F38,.W1, 0x66),  .RVM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBLENDMW,     ops3(.zmm_kz, .zmm, .zmm_m512),           evex(.L512,._66,._0F38,.W1, 0x66),  .RVM, .ZO, .{AVX512BW} ),
// VPBLENDMD / VPBLENDMQ
    // VPBLENDMD
    instr(.VPBLENDMD,     ops3(.xmm_kz,.xmm,.xmm_m128_m32bcst),     evex(.L128,._66,._0F38,.W0, 0x64),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBLENDMD,     ops3(.ymm_kz,.ymm,.ymm_m256_m32bcst),     evex(.L256,._66,._0F38,.W0, 0x64),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBLENDMD,     ops3(.zmm_kz,.zmm,.zmm_m512_m32bcst),     evex(.L512,._66,._0F38,.W0, 0x64),  .RVM, .ZO, .{AVX512F} ),
    // VPBLENDMQ
    instr(.VPBLENDMQ,     ops3(.xmm_kz,.xmm,.xmm_m128_m64bcst),     evex(.L128,._66,._0F38,.W1, 0x64),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBLENDMQ,     ops3(.ymm_kz,.ymm,.ymm_m256_m64bcst),     evex(.L256,._66,._0F38,.W1, 0x64),  .RVM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBLENDMQ,     ops3(.zmm_kz,.zmm,.zmm_m512_m64bcst),     evex(.L512,._66,._0F38,.W1, 0x64),  .RVM, .ZO, .{AVX512F} ),
// VPBROADCASTB / VPBROADCASTW / VPBROADCASTD / VPBROADCASTQ
    // VPBROADCASTB
    instr(.VPBROADCASTB,     ops2(.xmml, .xmml_m8),                  vex(.L128,._66,._0F38,.W0, 0x78),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTB,     ops2(.ymml, .xmml_m8),                  vex(.L256,._66,._0F38,.W0, 0x78),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTB,     ops2(.xmm_kz, .xmm_m8),                evex(.L128,._66,._0F38,.W0, 0x78),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.ymm_kz, .xmm_m8),                evex(.L256,._66,._0F38,.W0, 0x78),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.zmm_kz, .xmm_m8),                evex(.L512,._66,._0F38,.W0, 0x78),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.xmm_kz, .rm_reg8),               evex(.L128,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.ymm_kz, .rm_reg8),               evex(.L256,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.zmm_kz, .rm_reg8),               evex(.L512,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.xmm_kz, .rm_reg32),              evex(.L128,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.ymm_kz, .rm_reg32),              evex(.L256,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.zmm_kz, .rm_reg32),              evex(.L512,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.xmm_kz, .rm_reg64),              evex(.L128,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.ymm_kz, .rm_reg64),              evex(.L256,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTB,     ops2(.zmm_kz, .rm_reg64),              evex(.L512,._66,._0F38,.W0, 0x7A),  .vRM, .ZO, .{AVX512BW} ),
    // VPBROADCASTW
    instr(.VPBROADCASTW,     ops2(.xmml, .xmml_m16),                 vex(.L128,._66,._0F38,.W0, 0x79),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTW,     ops2(.ymml, .xmml_m16),                 vex(.L256,._66,._0F38,.W0, 0x79),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTW,     ops2(.xmm_kz, .xmm_m16),               evex(.L128,._66,._0F38,.W0, 0x79),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.ymm_kz, .xmm_m16),               evex(.L256,._66,._0F38,.W0, 0x79),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.zmm_kz, .xmm_m16),               evex(.L512,._66,._0F38,.W0, 0x79),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.xmm_kz, .rm_reg16),              evex(.L128,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.ymm_kz, .rm_reg16),              evex(.L256,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.zmm_kz, .rm_reg16),              evex(.L512,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.xmm_kz, .rm_reg32),              evex(.L128,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.ymm_kz, .rm_reg32),              evex(.L256,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.zmm_kz, .rm_reg32),              evex(.L512,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.xmm_kz, .rm_reg64),              evex(.L128,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.ymm_kz, .rm_reg64),              evex(.L256,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512VL, AVX512BW} ),
    instr(.VPBROADCASTW,     ops2(.zmm_kz, .rm_reg64),              evex(.L512,._66,._0F38,.W0, 0x7B),  .vRM, .ZO, .{AVX512BW} ),
    // VPBROADCASTD
    instr(.VPBROADCASTD,     ops2(.xmml, .xmml_m32),                 vex(.L128,._66,._0F38,.W0, 0x58),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTD,     ops2(.ymml, .xmml_m32),                 vex(.L256,._66,._0F38,.W0, 0x58),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTD,     ops2(.xmm_kz, .xmm_m32),               evex(.L128,._66,._0F38,.W0, 0x58),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTD,     ops2(.ymm_kz, .xmm_m32),               evex(.L256,._66,._0F38,.W0, 0x58),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTD,     ops2(.zmm_kz, .xmm_m32),               evex(.L512,._66,._0F38,.W0, 0x58),  .vRM, .ZO, .{AVX512F} ),
    instr(.VPBROADCASTD,     ops2(.xmm_kz, .rm_reg32),              evex(.L128,._66,._0F38,.W0, 0x7C),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTD,     ops2(.ymm_kz, .rm_reg32),              evex(.L256,._66,._0F38,.W0, 0x7C),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTD,     ops2(.zmm_kz, .rm_reg32),              evex(.L512,._66,._0F38,.W0, 0x7C),  .vRM, .ZO, .{AVX512F} ),
    // VPBROADCASTQ
    instr(.VPBROADCASTQ,     ops2(.xmml, .xmml_m64),                 vex(.L128,._66,._0F38,.W0, 0x59),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTQ,     ops2(.ymml, .xmml_m64),                 vex(.L256,._66,._0F38,.W0, 0x59),  .vRM, .ZO, .{AVX2} ),
    instr(.VPBROADCASTQ,     ops2(.xmm_kz, .xmm_m64),               evex(.L128,._66,._0F38,.W1, 0x59),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTQ,     ops2(.ymm_kz, .xmm_m64),               evex(.L256,._66,._0F38,.W1, 0x59),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTQ,     ops2(.zmm_kz, .xmm_m64),               evex(.L512,._66,._0F38,.W1, 0x59),  .vRM, .ZO, .{AVX512F} ),
    instr(.VPBROADCASTQ,     ops2(.xmm_kz, .rm_reg64),              evex(.L128,._66,._0F38,.W1, 0x7C),  .vRM, .ZO, .{AVX512VL, AVX512F, No32} ),
    instr(.VPBROADCASTQ,     ops2(.ymm_kz, .rm_reg64),              evex(.L256,._66,._0F38,.W1, 0x7C),  .vRM, .ZO, .{AVX512VL, AVX512F, No32} ),
    instr(.VPBROADCASTQ,     ops2(.zmm_kz, .rm_reg64),              evex(.L512,._66,._0F38,.W1, 0x7C),  .vRM, .ZO, .{AVX512F, No32} ),
    // VPBROADCASTI32X2
    instr(.VPBROADCASTI32X2, ops2(.xmm_kz, .xmm_m64),               evex(.L128,._66,._0F38,.W0, 0x59),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VPBROADCASTI32X2, ops2(.ymm_kz, .xmm_m64),               evex(.L256,._66,._0F38,.W0, 0x59),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VPBROADCASTI32X2, ops2(.zmm_kz, .xmm_m64),               evex(.L512,._66,._0F38,.W0, 0x59),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    // VPBROADCASTI128
    instr(.VPBROADCASTI128,  ops2(.ymml, .rm_mem128),                vex(.L256,._66,._0F38,.W0, 0x5A),  .vRM, .ZO, .{AVX2} ),
    // VPBROADCASTI32X4
    instr(.VPBROADCASTI32X4, ops2(.ymm_kz, .rm_mem128),             evex(.L256,._66,._0F38,.W0, 0x5A),  .vRM, .ZO, .{AVX512VL, AVX512F} ),
    instr(.VPBROADCASTI32X4, ops2(.zmm_kz, .rm_mem128),             evex(.L512,._66,._0F38,.W0, 0x5A),  .vRM, .ZO, .{AVX512F} ),
    // VPBROADCASTI64X2
    instr(.VPBROADCASTI64X2, ops2(.ymm_kz, .rm_mem128),             evex(.L256,._66,._0F38,.W1, 0x5A),  .vRM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VPBROADCASTI64X2, ops2(.zmm_kz, .rm_mem128),             evex(.L512,._66,._0F38,.W1, 0x5A),  .vRM, .ZO, .{AVX512DQ} ),
    // VPBROADCASTI32X8
    instr(.VPBROADCASTI32X8, ops2(.zmm_kz, .rm_mem256),             evex(.L512,._66,._0F38,.W0, 0x5B),  .vRM, .ZO, .{AVX512DQ} ),
    // VPBROADCASTI64X4
    instr(.VPBROADCASTI64X4, ops2(.zmm_kz, .rm_mem256),             evex(.L512,._66,._0F38,.W1, 0x5B),  .vRM, .ZO, .{AVX512F} ),
// VPBROADCASTM
    // VPBROADCASTMB2Q
    instr(.VPBROADCASTMB2Q,  ops2(.xmm_kz, .rm_k),                  evex(.L128,._F3,._0F38,.W1, 0x2A),  .vRM, .ZO, .{AVX512VL, AVX512CD} ),
    instr(.VPBROADCASTMB2Q,  ops2(.ymm_kz, .rm_k),                  evex(.L256,._F3,._0F38,.W1, 0x2A),  .vRM, .ZO, .{AVX512VL, AVX512CD} ),
    instr(.VPBROADCASTMB2Q,  ops2(.zmm_kz, .rm_k),                  evex(.L512,._F3,._0F38,.W1, 0x2A),  .vRM, .ZO, .{AVX512CD} ),
    // VPBROADCASTMW2D
    instr(.VPBROADCASTMW2D,  ops2(.xmm_kz, .rm_k),                  evex(.L128,._F3,._0F38,.W0, 0x3A),  .vRM, .ZO, .{AVX512VL, AVX512CD} ),
    instr(.VPBROADCASTMW2D,  ops2(.ymm_kz, .rm_k),                  evex(.L256,._F3,._0F38,.W0, 0x3A),  .vRM, .ZO, .{AVX512VL, AVX512CD} ),
    instr(.VPBROADCASTMW2D,  ops2(.zmm_kz, .rm_k),                  evex(.L512,._F3,._0F38,.W0, 0x3A),  .vRM, .ZO, .{AVX512CD} ),
// VPCMPB / VPCMPUB
// VPCMPD / VPCMPUD
// VPCMPQ / VPCMPUQ
// VPCMPW / VPCMPUW
// VPCOMPRESSB / VPCOMPRESSW
// VPCOMPRESSD
// VPCOMPRESSQ
// VPCONFLICTD / CPCONFLICTQ
// VPDPBUSD
// VPDPBUSDS
// VPDPWSSD
// VPDPWSSDS
// VPERM2F128
    // AVX
// VPERM2I128
    // AVX
// VPERMB
// VPERMD / VPERMW
    // AVX
// VPERMI2B
// VPERMI2W / VPERMI2D / VPERMI2Q / VPERMI2PS / VPERMI2PD
// VPERMILPD
    // AVX
// VPERMILPS
    // AVX
// VPERMPD
    // AVX
// VPERMPS
    // AVX
// VPERMQ
    // AVX
// VPERMT2B
// VPERMT2W / VPERMT2D / VPERMT2Q / VPERMT2PS / VPERMT2PD
// VPEXPANDB / VPEXPANDW
// VPEXPANDD
// VPEXPANDQ
// VPGATHERDD / VPGATHERQD
    // AVX
// VPGATHERDD / VPGATHERDQ
// VPGATHERDQ / VPGATHERQQ
    // AVX
// VPGATHERQD / VPGATHERQQ
// VPLZCNTD / VPLZCNTQ
// VPMADD52HUQ
// VPMADD52LUQ
// VPMASKMOV
    // AVX
// VPMOVB2M / VPMOVW2M / VPMOVD2M / VPMOVQ2M
// VPMOVDB / VPMOVSDB / VPMOVUSDB
// VPMOVDW / VPMOVSDB / VPMOVUSDB
// VPMOVM2B / VPMOVM2W / VPMOVM2D / VPMOVM2Q
// VPMOVQB / VPMOVSQB / VPMOVUSQB
// VPMOVQD / VPMOVSQD / VPMOVUSQD
// VPMOVQW / VPMOVSQW / VPMOVUSQW
// VPMOVWB / VPMOVSWB / VPMOVUSWB
// VPMULTISHIFTQB
// VPOPCNT
// VPROLD / VPROLVD / VPROLQ / VPROLVQ
// VPRORD / VPRORVD / VPRORQ / VPRORVQ
// VPSCATTERDD / VPSCATTERDQ / VPSCATTERQD / VPSCATTERQQ
// VPSHLD
// VPSHLDV
// VPSHRD
// VPSHRDV
// VPSHUFBITQMB
// VPSLLVW / VPSLLVD / VPSLLVQ
    // AVX
// VPSRAVW / VPSRAVD / VPSRAVQ
    // AVX
// VPSRLVW / VPSRLVD / VPSRLVQ
    // AVX
// VPTERNLOGD / VPTERNLOGQ
// VPTESTMB / VPTESTMW / VPTESTMD / VPTESTMQ
// VPTESTNMB / VPTESTNMW / VPTESTNMD / VPTESTNMQ
// VRANGEPD / VRANGEPS / VRANGESD / VRANGESS
// VRCP14PD / VRCP14PS / VRCP14SD / VRCP14SS
// VREDUCEPD / VREDUCEPS / VREDUCESD / VREDUCESS
// VRNDSCALEPD / VRNDSCALEPS / VRNDSCALESD / VRNDSCALESS
// VRSQRT14PD / VRSQRT14PS / VRSQRT14SD / VRSQRT14SS
// VSCALEFPD / VSCALEFPS / VSCALEFSD / VSCALEFSS
// VSCATTERDPS / VSCATTERDPD / VSCATTERQPS / VSCATTERQPD
// VSHUFF32x4 / VSHUFF64x2 / VSHUFI32x4 / VSHUFI64x2
// VTESTPD / VTESTPS
    // AVX
// VXORPD
    instr(.VXORPD,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._66,._0F,.WIG, 0x57),   .RVM, .ZO, .{AVX} ),
    instr(.VXORPD,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._66,._0F,.WIG, 0x57),   .RVM, .ZO, .{AVX} ),
    instr(.VXORPD,     ops3(.xmm_kz, .xmm, .xmm_m128_m64bcst),     evex(.L128,._66,._0F,.W1,  0x57),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VXORPD,     ops3(.ymm_kz, .ymm, .ymm_m256_m64bcst),     evex(.L256,._66,._0F,.W1,  0x57),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VXORPD,     ops3(.zmm_kz, .zmm, .zmm_m512_m64bcst),     evex(.L512,._66,._0F,.W1,  0x57),   .RVM, .ZO, .{AVX512DQ} ),
// VXXORPS
    instr(.VXORPS,     ops3(.xmml, .xmml, .xmml_m128),              vex(.L128,._NP,._0F,.WIG, 0x57),   .RVM, .ZO, .{AVX} ),
    instr(.VXORPS,     ops3(.ymml, .ymml, .ymml_m256),              vex(.L256,._NP,._0F,.WIG, 0x57),   .RVM, .ZO, .{AVX} ),
    instr(.VXORPS,     ops3(.xmm_kz, .xmm, .xmm_m128_m32bcst),     evex(.L128,._NP,._0F,.W0,  0x57),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VXORPS,     ops3(.ymm_kz, .ymm, .ymm_m256_m32bcst),     evex(.L256,._NP,._0F,.W0,  0x57),   .RVM, .ZO, .{AVX512VL, AVX512DQ} ),
    instr(.VXORPS,     ops3(.zmm_kz, .zmm, .zmm_m512_m32bcst),     evex(.L512,._NP,._0F,.W0,  0x57),   .RVM, .ZO, .{AVX512DQ} ),
// VZEROALL
    instr(.VZEROALL,   ops0(),                                  vex(.L256,._NP,._0F,.WIG, 0x77),   .vZO, .ZO, .{AVX} ),
// VZEROUPPER
    instr(.VZEROUPPER, ops0(),                                  vex(.L128,._NP,._0F,.WIG, 0x77),   .vZO, .ZO, .{AVX} ),

//
// AVX512 mask register instructions
//
// KADDW / KADDB / KADDD / KADDQ
    instr(.KADDB,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x4A),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KADDW,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x4A),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KADDD,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x4A),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KADDQ,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x4A),    .RVM, .ZO, .{AVX512BW} ),
// KANDW / KANDB / KANDD / KANDQ
    instr(.KANDB,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x41),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KANDW,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x41),    .RVM, .ZO, .{AVX512F} ),
    instr(.KANDD,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x41),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KANDQ,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x41),    .RVM, .ZO, .{AVX512BW} ),
// KANDNW / KANDNB / KANDND / KANDNQ
    instr(.KANDNB,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x42),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KANDNW,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x42),    .RVM, .ZO, .{AVX512F} ),
    instr(.KANDND,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x42),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KANDNQ,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x42),    .RVM, .ZO, .{AVX512BW} ),
// KNOTW / KNOTB / KNOTD / KNOTQ
    instr(.KNOTB,      ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W0, 0x44),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KNOTW,      ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W0, 0x44),    .vRM, .ZO, .{AVX512F} ),
    instr(.KNOTD,      ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W1, 0x44),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KNOTQ,      ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W1, 0x44),    .vRM, .ZO, .{AVX512BW} ),
// KORW / KORB / KORD / KORQ
    instr(.KORB,       ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x45),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KORW,       ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x45),    .RVM, .ZO, .{AVX512F} ),
    instr(.KORD,       ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x45),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KORQ,       ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x45),    .RVM, .ZO, .{AVX512BW} ),
// KORTESTW / KORTESTB / KORTESTD / KORTESTQ
    instr(.KORTESTB,   ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W0, 0x98),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KORTESTW,   ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W0, 0x98),    .vRM, .ZO, .{AVX512F} ),
    instr(.KORTESTD,   ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W1, 0x98),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KORTESTQ,   ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W1, 0x98),    .vRM, .ZO, .{AVX512BW} ),
// KMOVW / KMOVB / KMOVD / KMOVQ
    instr(.KMOVB,      ops2(.reg_k, .k_m8),             vex(.LZ,._66,._0F,.W0, 0x90),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KMOVB,      ops2(.rm_mem8, .reg_k),          vex(.LZ,._66,._0F,.W0, 0x91),    .vMR, .ZO, .{AVX512DQ} ),
    instr(.KMOVB,      ops2(.reg_k, .reg32),            vex(.LZ,._66,._0F,.W0, 0x92),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KMOVB,      ops2(.reg32, .reg_k),            vex(.LZ,._66,._0F,.W0, 0x93),    .vRM, .ZO, .{AVX512DQ} ),
    //
    instr(.KMOVW,      ops2(.reg_k, .k_m16),            vex(.LZ,._NP,._0F,.W0, 0x90),    .vRM, .ZO, .{AVX512F} ),
    instr(.KMOVW,      ops2(.rm_mem16, .reg_k),         vex(.LZ,._NP,._0F,.W0, 0x91),    .vMR, .ZO, .{AVX512F} ),
    instr(.KMOVW,      ops2(.reg_k, .reg32),            vex(.LZ,._NP,._0F,.W0, 0x92),    .vRM, .ZO, .{AVX512F} ),
    instr(.KMOVW,      ops2(.reg32, .reg_k),            vex(.LZ,._NP,._0F,.W0, 0x93),    .vRM, .ZO, .{AVX512F} ),
    //
    instr(.KMOVD,      ops2(.reg_k, .k_m32),            vex(.LZ,._66,._0F,.W1, 0x90),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KMOVD,      ops2(.rm_mem32, .reg_k),         vex(.LZ,._66,._0F,.W1, 0x91),    .vMR, .ZO, .{AVX512BW} ),
    instr(.KMOVD,      ops2(.reg_k, .reg32),            vex(.LZ,._F2,._0F,.W0, 0x92),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KMOVD,      ops2(.reg32, .reg_k),            vex(.LZ,._F2,._0F,.W0, 0x93),    .vRM, .ZO, .{AVX512BW} ),
    //
    instr(.KMOVQ,      ops2(.reg_k, .k_m64),            vex(.LZ,._NP,._0F,.W1, 0x90),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KMOVQ,      ops2(.rm_mem64, .reg_k),         vex(.LZ,._NP,._0F,.W1, 0x91),    .vMR, .ZO, .{AVX512BW} ),
    instr(.KMOVQ,      ops2(.reg_k, .reg64),            vex(.LZ,._F2,._0F,.W1, 0x92),    .vRM, .ZO, .{AVX512BW, No32} ),
    instr(.KMOVQ,      ops2(.reg64, .reg_k),            vex(.LZ,._F2,._0F,.W1, 0x93),    .vRM, .ZO, .{AVX512BW, No32} ),
// KSHIFTLW / KSHIFTLB / KSHIFTLD / KSHIFTLQ
    instr(.KSHIFTLB,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W0, 0x32),  .vRMI,.ZO, .{AVX512DQ} ),
    instr(.KSHIFTLW,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W1, 0x32),  .vRMI,.ZO, .{AVX512F} ),
    instr(.KSHIFTLD,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W0, 0x33),  .vRMI,.ZO, .{AVX512BW} ),
    instr(.KSHIFTLQ,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W1, 0x33),  .vRMI,.ZO, .{AVX512BW} ),
// KSHIFTRW / KSHIFTRB / KSHIFTRD / KSHIFTRQ
    instr(.KSHIFTRB,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W0, 0x30),  .vRMI,.ZO, .{AVX512DQ} ),
    instr(.KSHIFTRW,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W1, 0x30),  .vRMI,.ZO, .{AVX512F} ),
    instr(.KSHIFTRD,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W0, 0x31),  .vRMI,.ZO, .{AVX512BW} ),
    instr(.KSHIFTRQ,   ops3(.reg_k, .reg_k, .imm8),     vex(.LZ,._66,._0F3A,.W1, 0x31),  .vRMI,.ZO, .{AVX512BW} ),
// KTESTW / KTESTB / KTESTD / KTESTQ
    instr(.KTESTB,     ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W0, 0x99),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KTESTW,     ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W0, 0x99),    .vRM, .ZO, .{AVX512DQ} ),
    instr(.KTESTD,     ops2(.reg_k, .reg_k),            vex(.LZ,._66,._0F,.W1, 0x99),    .vRM, .ZO, .{AVX512BW} ),
    instr(.KTESTQ,     ops2(.reg_k, .reg_k),            vex(.LZ,._NP,._0F,.W1, 0x99),    .vRM, .ZO, .{AVX512BW} ),
// KUNPCKBW / KUNPCKWD / KUNPCKDQ
    instr(.KUNPCKBW,   ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x4B),    .RVM, .ZO, .{AVX512F} ),
    instr(.KUNPCKWD,   ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x4B),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KUNPCKDQ,   ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x4B),    .RVM, .ZO, .{AVX512BW} ),
// KXNORW / KXNORB / KXNORD / KXNORQ
    instr(.KXNORB,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x46),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KXNORW,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x46),    .RVM, .ZO, .{AVX512F} ),
    instr(.KXNORD,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x46),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KXNORQ,     ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x46),    .RVM, .ZO, .{AVX512BW} ),
// KXORW / KXORB / KXORD / KXORQ
    instr(.KXORB,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W0, 0x47),    .RVM, .ZO, .{AVX512DQ} ),
    instr(.KXORW,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W0, 0x47),    .RVM, .ZO, .{AVX512F} ),
    instr(.KXORD,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._66,._0F,.W1, 0x47),    .RVM, .ZO, .{AVX512BW} ),
    instr(.KXORQ,      ops3(.reg_k, .reg_k, .reg_k),    vex(.L1,._NP,._0F,.W1, 0x47),    .RVM, .ZO, .{AVX512BW} ),

    // Dummy sigil value that marks the end of the table, use this to avoid
    // extra bounds checking when scanning this table.
    instr(._mnemonic_final,  ops0(), Opcode{}, .ZO, .ZO, .{} ),
};

