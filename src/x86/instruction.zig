const std = @import("std");
const assert = std.debug.assert;

const x86 = @import("machine.zig");

usingnamespace (@import("types.zig"));

const ModRmResult = x86.operand.ModRmResult;
const Immediate = x86.operand.Immediate;
const Address = x86.operand.Address;
const MOffsetDisp = x86.operand.MOffsetDisp;
const Register = x86.Register;
const AvxOpcode = x86.avx.AvxOpcode;
const AvxResult = x86.avx.AvxResult;
const InstructionItem = x86.database.InstructionItem;

// LegacyPrefixes | REX/VEX/EVEX | OPCODE(0,1,2,3) | ModRM | SIB | displacement(0,1,2,4) | immediate(0,1,2,4)
pub const prefix_max_len = 4;
pub const ext_max_len = 1;
pub const opcode_max_len = 4;
pub const modrm_max_len = 1;
pub const sib_max_len = 1;
pub const displacement_max_len = 8;
pub const immediate_max_len = 8;
pub const instruction_max_len = 15;

pub const ViewPtr = struct {
    offset: u8 = 0,
    size: u8 = 0,
};

/// Slices to parts of an instruction
pub const View = struct {
    prefix: ViewPtr = ViewPtr{},
    ext: ViewPtr = ViewPtr{},
    opcode: ViewPtr = ViewPtr{},
    modrm: ViewPtr = ViewPtr{},
    sib: ViewPtr = ViewPtr{},
    displacement: ViewPtr = ViewPtr{},
    immediate: ViewPtr = ViewPtr{},
};

pub const Instruction = struct {
    pub const max_length = 15;
    data: [max_length]u8 = undefined,
    len: u8 = 0,
    view: View = View{},

    pub fn asSlice(self: @This()) []const u8 {
        return self.data[0..self.len];
    }

    pub fn asMutSlice(self: *@This()) []u8 {
        return self.data[0..self.len];
    }

    fn viewSlice(self: @This(), vptr: ?ViewPtr) ?[]const u8 {
        if (vptr) |v| {
            return self.data[v.offset..(v.offset + v.size)];
        } else {
            return null;
        }
    }

    fn viewMutSlice(self: *@This(), vptr: ?ViewPtr) ?[]u8 {
        if (vptr) |v| {
            return self.data[v.offset..(v.offset + v.size)];
        } else {
            return null;
        }
    }

    fn debugPrint(self: @This()) void {
        const warn = if (true) std.debug.warn else util.warnDummy;
        warn("Instruction {{", .{});
        if (self.view.prefix.size != 0) {
            warn(" Pre:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.prefix))});
        }
        if (self.view.ext.size != 0) {
            warn(" Ext:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.ext))});
        }
        if (self.view.opcode.size != 0) {
            warn(" Op:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.opcode))});
        }
        if (self.view.modrm.size != 0) {
            warn(" Rm:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.modrm))});
        }
        if (self.view.sib.size != 0) {
            warn(" Sib:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.sib))});
        }
        if (self.view.displacement.size != 0) {
            warn(" Dis:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.displacement))});
        }
        if (self.view.immediate.size != 0) {
            warn(" Imm:{}", .{std.fmt.fmtSliceHexLower(self.viewSlice(self.view.immediate))});
        }
        warn(" }}\n", .{});
    }

    fn makeViewPart(self: *@This(), size: u8) ViewPtr {
        assert(self.len + size <= max_length);
        return ViewPtr{
            .offset = @intCast(u8, self.len),
            .size = size,
        };
    }

    fn addBytes(self: *@This(), bytes: []const u8) void {
        std.mem.copy(u8, self.data[self.len..], bytes[0..]);
        self.len += @intCast(u8, bytes.len);
    }

    fn addByte(self: *@This(), byte: u8) void {
        self.data[self.len] = byte;
        self.len += 1;
    }

    fn addPrefixSlice(self: *@This(), prefix_slice: []const Prefix) void {
        for (prefix_slice) |pre| {
            if (pre == .None) {
                break;
            }
            self.addByte(@enumToInt(pre));
        }
    }

    fn checkLengthError(
        instr_item: *const InstructionItem,
        enc_ctrl: *const EncodingControl,
        prefixes: Prefixes,
        modrm_: ?ModRmResult,
    ) AsmError!void {
        var len = instr_item.calcLengthLegacy(modrm_);
        if (modrm_ != null and modrm_.?.isRexRequired()) {
            len += 1;
        }
        len += enc_ctrl.prefixCount();
        if (!enc_ctrl.useExactPrefixes()) {
            len += prefixes.len;
        }
        if (len > Instruction.max_length) {
            return AsmError.InstructionTooLong;
        }
    }

    pub fn addUserPrefixes(
        self: *@This(),
        ctrl: *const EncodingControl,
        prefixes: Prefixes,
    ) AsmError!void {
        self.addPrefixSlice(ctrl.prefixes[0..]);
        if (ctrl.useExactPrefixes() and !ctrl.hasNecessaryPrefixes(prefixes)) {
            return AsmError.InvalidPrefixes;
        }
        if (!ctrl.useExactPrefixes()) {
            self.addPrefixSlice(prefixes.prefixes[0..]);
        }
    }

    pub fn addStandardPrefixes(self: *@This(), prefix: Prefixes, opcode: Opcode) void {
        if (prefix.len == 0 and !opcode.hasPrefixByte()) {
            return;
        }

        if (opcode.hasPrefixByte()) {
            self.view.prefix = self.makeViewPart(prefix.len + 1);
            self.addBytes(prefix.asSlice());
            self.addByte(@enumToInt(opcode.prefix));
        } else {
            self.view.prefix = self.makeViewPart(prefix.len);
            self.addBytes(prefix.asSlice());
        }
    }

    pub fn addPrefixes(
        self: *@This(),
        instr_item: *const InstructionItem,
        enc_ctrl: ?*const EncodingControl,
        prefixes: Prefixes,
        modrm_: ?ModRmResult,
        opcode: Opcode,
    ) AsmError!void {
        if (enc_ctrl) |ctrl| {
            var normal_prefixes = prefixes;
            if (opcode.hasPrefixByte()) {
                normal_prefixes.addPrefix(@intToEnum(Prefix, @enumToInt(opcode.prefix)));
            }
            try checkLengthError(instr_item, ctrl, normal_prefixes, modrm_);
            try self.addUserPrefixes(ctrl, normal_prefixes);
        } else {
            self.addStandardPrefixes(prefixes, opcode);
        }
    }

    // TODO: need to handle more cases, and those interacting with different addressing modes
    pub fn addRex(self: *@This(), mode: Mode86, reg: ?Register, rm: ?Register, overides: Overides) AsmError!void {
        const reg_num = if (reg == null) 0 else reg.?.number();
        const rm_num = if (rm == null) 0 else rm.?.number();
        var needs_rex = false;
        var needs_no_rex = false;
        var w: u1 = 0;

        if (reg != null and reg.?.needsRex()) {
            needs_rex = true;
        }
        if (rm != null and rm.?.needsRex()) {
            needs_rex = true;
        }

        if (reg != null and reg.?.needsNoRex()) {
            needs_no_rex = true;
        }
        if (rm != null and rm.?.needsNoRex()) {
            needs_no_rex = true;
        }

        if (!overides.is64Default()) {
            if (reg != null and reg.?.bitSize() == .Bit64) {
                w = 1;
            }
            if (rm != null and rm.?.bitSize() == .Bit64) {
                w = 1;
            }
        }

        const r: u8 = if (reg_num < 8) 0 else 1;
        const x: u8 = 0;
        const b: u8 = if (rm_num < 8) 0 else 1;
        const rex_byte: u8 = ((0x40) | (@as(u8, w) << 3) | (r << 2) | (x << 1) | (b << 0));

        if (rex_byte != 0x40 or needs_rex) {
            if (mode != .x64) {
                return AsmError.InvalidMode;
            }

            if (needs_no_rex) {
                return AsmError.InvalidRegisterCombination;
            }

            self.view.ext = self.makeViewPart(1);
            self.addByte(rex_byte);
        }
    }

    pub fn addAvx(self: *@This(), mode: Mode86, info: AvxResult) AsmError!void {
        switch (info.encoding) {
            .Vex2 => {
                self.view.ext = self.makeViewPart(2);
                self.addBytes(&info.makeVex2());
            },

            .Vex3 => {
                self.view.ext = self.makeViewPart(3);
                self.addBytes(&info.makeVex3());
            },

            .Evex => {
                self.view.ext = self.makeViewPart(4);
                self.addBytes(&info.makeEvex());
            },

            .Xop => {
                self.view.ext = self.makeViewPart(3);
                self.addBytes(&info.makeXop());
            },
        }
    }

    pub fn rexRaw(self: *@This(), mode: Mode86, rex_byte: u8) AsmError!void {
        if (rex_byte != 0x40) {
            if (mode != .x64) {
                return AsmError.InvalidMode;
            }
            self.view.ext = self.makeViewPart(1);
            self.addByte(rex_byte);
        }
    }

    pub fn addRexRm(self: *@This(), mode: Mode86, w: u1, rm: ModRmResult) AsmError!void {
        const rex_byte = rm.rex(w);

        if (rm.needs_rex and rm.needs_no_rex) {
            return AsmError.InvalidRegisterCombination;
        }

        if (rex_byte != 0x40 or rm.needs_rex) {
            if (mode != .x64) {
                return AsmError.InvalidMode;
            }
            if (rm.needs_no_rex) {
                return AsmError.InvalidRegisterCombination;
            }

            self.view.ext = self.makeViewPart(1);
            self.addByte(rex_byte);
        }
    }

    pub fn modrm(self: *@This(), rm: ModRmResult) void {
        self.view.modrm = self.makeViewPart(1);
        self.addByte(rm.modrm());

        if (rm.sib) |sib| {
            self.view.sib = self.makeViewPart(1);
            self.addByte(sib);
        }

        switch (rm.disp_bit_size) {
            .None => {},
            .Bit8 => self.addDisp8(@intCast(i8, rm.disp)),
            .Bit16 => self.addDisp16(@intCast(i16, rm.disp)),
            .Bit32 => self.addDisp32(rm.disp),
            else => unreachable,
        }
    }

    /// Add the opcode to instruction.
    pub fn addCompoundOpcode(self: *@This(), op: Opcode) void {
        if (op.compound_op != .None) {
            self.addByte(@enumToInt(op.compound_op));
        }
    }

    /// Add the opcode to instruction.
    pub fn addOpcode(self: *@This(), op: Opcode) void {
        self.view.opcode = self.makeViewPart(op.len);
        self.addBytes(op.asSlice());
    }

    /// Add the opcode to instruction.
    pub fn addOpcodeByte(self: *@This(), op: u8) void {
        self.view.opcode = self.makeViewPart(1);
        self.addByte(op);
    }

    /// Add the opcode to instruction incrementing the last byte by register number.
    pub fn addOpcodeRegNum(self: *@This(), op: Opcode, reg: Register) void {
        var modified_op = op;
        modified_op.opcode[modified_op.len - 1] += reg.number() & 0x07;
        self.view.opcode = self.makeViewPart(modified_op.len);
        self.addBytes(modified_op.asSlice());
    }

    /// Add the immediate to the instruction
    pub fn addImm(self: *@This(), imm: Immediate) void {
        switch (imm.size) {
            .Imm8, .Imm8_any => self.addImm8(imm.as8()),
            .Imm16, .Imm16_any => self.addImm16(imm.as16()),
            .Imm32, .Imm32_any => self.addImm32(imm.as32()),
            .Imm64, .Imm64_any => self.addImm64(imm.as64()),
        }
    }

    fn makeViewImmediate(self: *@This(), size: u8) void {
        if (self.view.immediate.size != 0) {
            self.view.immediate.size += size;
        } else {
            self.view.immediate = self.makeViewPart(size);
        }
        assert(self.view.immediate.size <= 8);
    }

    pub fn addImm8(self: *@This(), imm8: u8) void {
        self.makeViewImmediate(1);
        self.add8(imm8);
    }

    pub fn addImm16(self: *@This(), imm16: u16) void {
        self.makeViewImmediate(2);
        self.add16(imm16);
    }

    pub fn addImm32(self: *@This(), imm32: u32) void {
        self.makeViewImmediate(4);
        self.add32(imm32);
    }

    pub fn addImm64(self: *@This(), imm64: u64) void {
        self.makeViewImmediate(8);
        self.add64(imm64);
    }

    pub fn addDisp8(self: *@This(), disp8: i8) void {
        self.view.displacement = self.makeViewPart(1);
        self.add8(@bitCast(u8, disp8));
    }

    pub fn addDisp16(self: *@This(), disp16: i16) void {
        self.view.displacement = self.makeViewPart(2);
        self.add16(@bitCast(u16, disp16));
    }

    pub fn addDisp32(self: *@This(), disp32: i32) void {
        self.view.displacement = self.makeViewPart(4);
        self.add32(@bitCast(u32, disp32));
    }

    pub fn addDisp64(self: *@This(), disp64: i64) void {
        self.view.displacement = self.makeViewPart(8);
        self.add64(@bitCast(u64, disp64));
    }

    pub fn add8(self: *@This(), imm8: u8) void {
        self.addByte(imm8);
    }

    pub fn add16(self: *@This(), imm16: u16) void {
        self.addByte(@intCast(u8, (imm16 >> 0) & 0xFF));
        self.addByte(@intCast(u8, (imm16 >> 8) & 0xFF));
    }

    pub fn add32(self: *@This(), imm32: u32) void {
        self.addByte(@intCast(u8, (imm32 >> 0) & 0xFF));
        self.addByte(@intCast(u8, (imm32 >> 8) & 0xFF));
        self.addByte(@intCast(u8, (imm32 >> 16) & 0xFF));
        self.addByte(@intCast(u8, (imm32 >> 24) & 0xFF));
    }

    pub fn add64(self: *@This(), imm64: u64) void {
        self.addByte(@intCast(u8, (imm64 >> 0) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 8) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 16) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 24) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 32) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 40) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 48) & 0xFF));
        self.addByte(@intCast(u8, (imm64 >> 56) & 0xFF));
    }

    pub fn addMOffsetDisp(self: *@This(), disp: MOffsetDisp) void {
        switch (disp) {
            .Disp16 => self.add16(disp.Disp16),
            .Disp32 => self.add32(disp.Disp32),
            .Disp64 => self.add64(disp.Disp64),
        }
    }

    pub fn addAddress(self: *@This(), addr: Address) void {
        const disp = addr.getDisp();

        switch (addr) {
            .FarJmp => |far| {
                const disp_size = disp.bitSize();
                assert(disp_size != .Bit64);
                self.view.immediate = self.makeViewPart(@intCast(u8, disp_size.valueBytes()) + 2);
                self.addMOffsetDisp(disp);
                self.add16(far.segment);
            },
            .MOffset => |moff| {
                const disp_size = disp.bitSize();
                self.view.immediate = self.makeViewPart(@intCast(u8, disp_size.valueBytes()));
                self.addMOffsetDisp(disp);
            },
        }
    }
};
