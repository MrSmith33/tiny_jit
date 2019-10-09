/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

/// Convertion of function IR to textual representation
module ir.dump;

import std.stdio;
import std.format : formattedWrite;

import all;

struct IrDumpContext
{
	CompilationContext* context;
	IrFunction* ir;
	FuncDumpSettings* settings; // nullable, uses default if null
	TextSink* sink; // nullable, writes to stdout if null
	LivenessInfo* liveness; // nullable, doesn't print liveness if null
}

struct InstrPrintInfo
{
	CompilationContext* context;
	TextSink* sink;
	IrFunction* ir;
	IrIndex blockIndex;
	IrBasicBlock* block;
	IrIndex instrIndex;
	IrInstrHeader* instrHeader;
	FuncDumpSettings* settings;
	IrDumpHandlers* handlers;
	void dumpInstr() { handlers.instrDumper(this); }
}

struct IrDumpHandlers
{
	InstructionDumper instrDumper;
	IrIndexDumper indexDumper;
}

struct IrIndexDump
{
	this(IrIndex index, ref InstrPrintInfo printInfo) {
		this.index = index;
		this.context = printInfo.context;
		this.instrSet = printInfo.ir.instructionSet;
	}
	this(IrIndex index, CompilationContext* context, IrFunction* ir) {
		this.index = index;
		this.context = context;
		this.instrSet = ir.instructionSet;
	}
	IrIndex index;
	IrInstructionSet instrSet;
	CompilationContext* context;

	void toString(scope void delegate(const(char)[]) sink) {
		instrSetDumpHandlers[instrSet].indexDumper(sink, *context, index);
	}
}

alias InstructionDumper = void function(ref InstrPrintInfo p);
alias IrIndexDumper = void function(scope void delegate(const(char)[]) sink, ref CompilationContext, IrIndex);

struct FuncDumpSettings
{
	bool printVars = false;
	bool printBlockFlags = false;
	bool printBlockIns = true;
	bool printBlockOuts = false;
	bool printBlockRefs = false;
	bool printInstrIndexEnabled = true;
	bool printLivenessLinearIndex = false;
	bool printVregLiveness = false;
	bool printPregLiveness = false;
	bool printUses = true;
	bool printLiveness = false;
	bool escapeForDot = false;
}

IrDumpHandlers[] instrSetDumpHandlers = [
	IrDumpHandlers(&dumpIrInstr, &dumpIrIndex),
	IrDumpHandlers(&dumpAmd64Instr, &dumpLirAmd64Index),
];

void dumpTypes(ref TextSink sink, ref CompilationContext ctx)
{
	IrIndex type = ctx.types.firstType;
	while (type.isDefined)
	{
		sink.putfln("%s", IrTypeDump(type, ctx));
		type = ctx.types.get!IrTypeHeader(type).nextType;
	}
}

void dumpFunction(CompilationContext* context, IrFunction* ir)
{
	IrDumpContext dumpCtx = { context : context, ir : ir };
	dumpFunction(&dumpCtx);
}

void dumpFunction(IrDumpContext* c)
{
	assert(c.context, "context is null");
	assert(c.ir, "ir is null");

	bool defaultSink = false;
	TextSink sink;
	FuncDumpSettings settings;

	if (c.sink is null) {
		defaultSink = true;
		c.sink = &sink;
	}

	if (c.settings is null) {
		c.settings = &settings;
	}

	dumpFunctionImpl(c);

	if (defaultSink) writeln(sink.text);
}

void dumpFunctionImpl(IrDumpContext* c)
{
	IrFunction* ir = c.ir;
	TextSink* sink = c.sink;
	CompilationContext* ctx = c.context;
	FuncDumpSettings* settings = c.settings;
	LivenessInfo* liveness = c.liveness;

	InstrPrintInfo printer;
	printer.context = ctx;
	printer.sink = sink;
	printer.ir = ir;
	printer.handlers = &instrSetDumpHandlers[ir.instructionSet];
	printer.settings = settings;

	sink.put("func ");
	// results
	auto funcType = &ctx.types.get!IrTypeFunction(ir.type);
	foreach(i, result; funcType.resultTypes) {
		if (i > 0) sink.put(", ");
		sink.putf("%s", IrIndexDump(result, printer));
	}
	if (funcType.numResults > 0) sink.put(" ");
	sink.put(ctx.idString(ir.backendData.name));

	// parameters
	sink.put("(");
	foreach(i, param; funcType.parameterTypes) {
		if (i > 0) sink.put(", ");
		sink.putf("%s", IrIndexDump(param, printer));
	}
	sink.put(")");
	sink.putfln(` %s bytes ir:"%s" {`, ir.byteLength, instr_set_names[ir.instructionSet]);
	int indexPadding = max(ir.numBasicBlocks, ir.numInstructions).numDigitsInNumber10;
	int liveIndexPadding = 0;
	if (liveness) liveIndexPadding = liveness.maxLinearIndex.numDigitsInNumber10;

	void printInstrLiveness(IrIndex linearKeyIndex, IrIndex instrIndex) {
		if (!settings.printLiveness) return;
		if (liveness is null) return;

		uint linearInstrIndex = liveness.linearIndicies[linearKeyIndex];

		if (settings.printPregLiveness)
		{
			foreach(ref interval; liveness.physicalIntervals)
			{
				if (interval.coversPosition(linearInstrIndex))
					sink.put("┃");
				else
					sink.put(" ");
			}
			if (settings.printVregLiveness) sink.put("┇");
		}

		import std.bitmanip : BitArray;
		BitArray blockLiveIn;
		if (instrIndex.isBasicBlock)
		{
			blockLiveIn = liveness.bitmap.blockLiveInBits(instrIndex, ir);
		}

		if (settings.printVregLiveness)
		foreach(ref LiveInterval interval; liveness.virtualIntervals)
		{
			auto vreg = &ir.getVirtReg(interval.definition);

			if (interval.hasUseAt(linearInstrIndex))
			{
				if (vreg.definition == instrIndex)
					sink.put("D"); // virtual register is defined by this instruction / phi
				else
					sink.put("U");
			}
			else if (interval.coversPosition(linearInstrIndex))
			{
				if (vreg.definition == instrIndex)
					sink.put("D"); // virtual register is defined by this instruction / phi
				else
				{
					if (instrIndex.isBasicBlock && blockLiveIn[interval.definition.storageUintIndex])
						sink.put("┏"); // virtual register is in "live in" of basic block
					else
						sink.put("┃"); // virtual register is live in this position
				}
			}
			else
			{
				sink.put(" ");
			}
		}

		if (settings.printLivenessLinearIndex)
		{
			sink.putf(" %*s| ", liveIndexPadding, linearInstrIndex);
		}
	}

	void printInstrIndex(IrIndex someIndex) {
		import std.range : repeat;
		if (!settings.printInstrIndexEnabled) return;
		if (someIndex.isInstruction)
			sink.putf("%*s|", indexPadding, someIndex.storageUintIndex);
		else
			sink.putf("%s|", ' '.repeat(indexPadding));
	}

	void printRegUses(IrIndex result) {
		if (result.isPhysReg) return;
		if (result.isStackSlot) return;

		auto vreg = &ir.getVirtReg(result);
		sink.put(" users [");
		foreach (i, index; vreg.users.range(ir))
		{
			if (i > 0) sink.put(", ");
			sink.putf("%s", IrIndexDump(index, printer));
		}
		sink.put("]");
	}

	IrIndex blockIndex = ir.entryBasicBlock;
	IrBasicBlock* block;
	while (blockIndex.isDefined)
	{
		if (!blockIndex.isBasicBlock)
		{
			sink.putfln("  invalid block %s", IrIndexDump(blockIndex, printer));
			break;
		}

		block = &ir.getBlock(blockIndex);
		scope(exit) blockIndex = block.nextBlock;

		printer.blockIndex = blockIndex;
		printer.block = block;

		printInstrLiveness(blockIndex, blockIndex);
		printInstrIndex(blockIndex);
		sink.putf("  %s", IrIndexDump(blockIndex, printer));

		if (settings.printBlockFlags)
		{
			if (block.isSealed) sink.put(" S");
			else sink.put(" .");

			if (block.isFinished) sink.put("F");
			else sink.put(".");

			if (block.isLoopHeader) sink.put("L");
			else sink.put(".");
		}

		if (settings.printBlockIns && block.predecessors.length > 0)
		{
			sink.putf(" in(");
			foreach(i, predIndex; block.predecessors.range(ir)) {
				if (i > 0) sink.put(", ");
				sink.putf("%s", IrIndexDump(predIndex, printer));
			}
			sink.put(")");
		}
		if (settings.printBlockOuts && block.successors.length > 0)
		{
			sink.putf(" out(");
			foreach(i, succIndex; block.successors.range(ir)) {
				if (i > 0) sink.put(", ");
				sink.putf("%s", IrIndexDump(succIndex, printer));
			}
			sink.put(")");
		}
		sink.putln;

		// phis
		IrIndex phiIndex = block.firstPhi;
		IrPhi* phi;
		while (phiIndex.isDefined)
		{
			if (!phiIndex.isPhi)
			{
				sink.putfln("  invalid phi %s", IrIndexDump(phiIndex, printer));
				break;
			}

			phi = &ir.getPhi(phiIndex);
			scope(exit) phiIndex = phi.nextPhi;

			printInstrLiveness(blockIndex, phiIndex);
			printInstrIndex(phiIndex);
			sink.putf("    %s %s = %s(",
				IrIndexDump(phi.result, printer),
				IrIndexDump(ir.getVirtReg(phi.result).type, printer),
				IrIndexDump(phiIndex, printer));
			foreach(size_t arg_i, ref IrPhiArg phiArg; phi.args(ir))
			{
				if (arg_i > 0) sink.put(", ");
				sink.putf("%s", IrIndexDump(phiArg.basicBlock, printer));
				dumpArg(phiArg.value, printer);
			}
			sink.put(")");
			if (settings.printUses) printRegUses(phi.result);
			sink.putln;
		}

		// instrs
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			printInstrLiveness(instrIndex, instrIndex);
			printInstrIndex(instrIndex);

			// print instr
			printer.instrIndex = instrIndex;
			printer.instrHeader = &instrHeader;

			printer.dumpInstr();

			if (settings.printUses && instrHeader.hasResult) printRegUses(instrHeader.result(ir));
			sink.putln;
		}
	}

	sink.putln("}");
}

void dumpFunctionCFG(IrFunction* ir, ref TextSink sink, CompilationContext* ctx, ref FuncDumpSettings settings)
{
	settings.escapeForDot = true;
	sink.put(`digraph "`);
	sink.put("function ");
	sink.put(ctx.idString(ir.backendData.name));
	sink.putfln(`() %s bytes" {`, ir.byteLength * uint.sizeof);
	int indexPadding = ir.numInstructions.numDigitsInNumber10;

	InstrPrintInfo p;
	p.context = ctx;
	p.sink = &sink;
	p.ir = ir;
	p.settings = &settings;

	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		foreach(i, succIndex; block.successors.range(ir)) {
			sink.putfln("node_%s -> node_%s;",
				blockIndex.storageUintIndex, succIndex.storageUintIndex);
		}

		sink.putf(`node_%s [shape=record,label="{`, blockIndex.storageUintIndex);

		p.blockIndex = blockIndex;
		p.block = &block;

		sink.putf(`  %s`, IrIndexDump(blockIndex, p));
		sink.put(`\l`);

		// phis
		foreach(IrIndex phiIndex, ref IrPhi phi; block.phis(ir))
		{
			sink.putf("    %s %s = %s(",
				IrIndexDump(phi.result, p),
				IrIndexDump(ir.getVirtReg(phi.result).type, p),
				IrIndexDump(phiIndex, p));
			foreach(size_t arg_i, ref IrPhiArg phiArg; phi.args(ir))
			{
				if (arg_i > 0) sink.put(", ");
				sink.putf("%s %s", IrIndexDump(phiArg.value, p), IrIndexDump(phiArg.basicBlock, p));
			}
			sink.put(")");
			sink.put(`\l`);
		}

		// instrs
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			// print instr
			p.instrIndex = instrIndex;
			p.instrHeader = &instrHeader;
			p.dumpInstr();
			sink.put(`\l`);
		}
		sink.putfln(`}"];`);
	}

	sink.putln("}");
}

void dumpIrIndex(scope void delegate(const(char)[]) sink, ref CompilationContext context, IrIndex index)
{
	if (!index.isDefined) {
		sink("<null>");
		return;
	}

	final switch(index.kind) with(IrValueKind) {
		case none: sink.formattedWrite("0x%X", index.asUint); break;
		case listItem: sink.formattedWrite("l.%s", index.storageUintIndex); break;
		case instruction: sink.formattedWrite("i.%s", index.storageUintIndex); break;
		case basicBlock: sink.formattedWrite("@%s", index.storageUintIndex); break;
		case constant: sink.formattedWrite("%s", context.constants.get(index).i64); break;
		case constantAggregate:
			sink("{");
			foreach(i, m; context.constants.getAggregate(index).members) {
				if (i > 0) sink(", ");
				dumpIrIndex(sink, context, m);
			}
			sink("}");
			break;
		case global: sink.formattedWrite("g%s", index.storageUintIndex); break;
		case phi: sink.formattedWrite("phi%s", index.storageUintIndex); break;
		case stackSlot: sink.formattedWrite("s%s", index.storageUintIndex); break;
		case virtualRegister: sink.formattedWrite("v%s", index.storageUintIndex); break;
		case physicalRegister: sink.formattedWrite("r%s", index.storageUintIndex); break;
		case type: dumpIrType(sink, context, index); break;
		case variable: assert(false);
		case func: sink.formattedWrite("f%s", index.storageUintIndex); break;
	}
}

struct IrTypeDump
{
	this(IrIndex index, ref CompilationContext ctx) {
		this.index = index;
		this.ctx = &ctx;
	}
	IrIndex index;
	CompilationContext* ctx;

	void toString(scope void delegate(const(char)[]) sink) {
		dumpIrType(sink, *ctx, index);
	}
}

void dumpIrType(scope void delegate(const(char)[]) sink, ref CompilationContext ctx, IrIndex type)
{
	final switch(type.typeKind) with(IrTypeKind) {
		case basic: sink.formattedWrite("%s", cast(IrValueType)type.typeIndex); break;
		case pointer:
			dumpIrType(sink, ctx, ctx.types.get!IrTypePointer(type).baseType);
			sink("*");
			break;
		case array:
			auto array = ctx.types.get!IrTypeArray(type);
			sink.formattedWrite("[%s x ", array.size);
			dumpIrType(sink, ctx, array.elemType);
			sink("]");
			break;
		case struct_t:
			IrTypeStruct* struct_t = &ctx.types.get!IrTypeStruct(type);
			sink("{");
			foreach(i, IrTypeStructMember member; struct_t.members)
			{
				if (i > 0) sink(", ");
				dumpIrType(sink, ctx, member.type);
			}
			sink("}");
			break;
		case func_t:
			// results
			auto funcType = &ctx.types.get!IrTypeFunction(type);
			foreach(i, result; funcType.resultTypes) {
				if (i > 0) sink(", ");
				dumpIrType(sink, ctx, result);
			}

			// parameters
			sink("(");
			foreach(i, param; funcType.parameterTypes) {
				if (i > 0) sink(", ");
				dumpIrType(sink, ctx, param);
			}
			sink(")");
			break;
	}
}


void dumpIrInstr(ref InstrPrintInfo p)
{
	switch(p.instrHeader.op)
	{
		case IrOpcode.block_exit_unary_branch: dumpUnBranch(p); break;
		case IrOpcode.block_exit_binary_branch: dumpBinBranch(p); break;
		case IrOpcode.block_exit_jump: dumpJmp(p); break;

		case IrOpcode.parameter:
			uint paramIndex = p.ir.get!IrInstr_parameter(p.instrIndex).index(p.ir);
			dumpOptionalResult(p);
			p.sink.putf("parameter%s", paramIndex);
			break;

		case IrOpcode.block_exit_return_void:
			p.sink.put("     return");
			break;

		case IrOpcode.block_exit_return_value:
			p.sink.put("    return");
			dumpArg(p.instrHeader.arg(p.ir, 0), p);
			break;

		default:
			dumpOptionalResult(p);
			p.sink.putf("%s", cast(IrOpcode)p.instrHeader.op);
			dumpArgs(p);
			break;
	}
}

void dumpOptionalResult(ref InstrPrintInfo p)
{
	if (p.instrHeader.hasResult)
	{
		if (p.instrHeader.result(p.ir).isVirtReg)
		{
			p.sink.putf("    %s %s = ",
				IrIndexDump(p.instrHeader.result(p.ir), p),
				IrIndexDump(p.ir.getVirtReg(p.instrHeader.result(p.ir)).type, p));
		}
		else
		{
			p.sink.putf("    %s = ", IrIndexDump(p.instrHeader.result(p.ir), p));
		}
	}
	else
	{
		p.sink.put("    ");
	}
}

void dumpArgs(ref InstrPrintInfo p)
{
	foreach (i, IrIndex arg; p.instrHeader.args(p.ir))
	{
		if (i > 0) p.sink.put(",");
		dumpArg(arg, p);
	}
}

void dumpArg(IrIndex arg, ref InstrPrintInfo p)
{
	if (arg.isPhysReg)
	{
		p.sink.putf(" %s", IrIndexDump(arg, p));
	}
	else if (arg.isFunction)
	{
		FunctionDeclNode* func = p.context.getFunction(arg);
		p.sink.putf(" %s", p.context.idString(func.id));
	}
	else
	{
		if (arg.isDefined)
			p.sink.putf(" %s %s",
				IrIndexDump(p.ir.getValueType(p.context, arg), p),
				IrIndexDump(arg, p));
		else p.sink.put(" <null>");
	}
}

void dumpJmp(ref InstrPrintInfo p)
{
	p.sink.put("    jmp ");
	if (p.block.successors.length > 0)
		p.sink.putf("%s", IrIndexDump(p.block.successors[0, p.ir], p));
	else
		p.sink.put(p.settings.escapeForDot ? `\<null\>` : "<null>");
}

void dumpUnBranch(ref InstrPrintInfo p)
{
	p.sink.putf("    if %s", unaryCondStrings[p.instrHeader.cond]);
	dumpArg(p.instrHeader.arg(p.ir, 0), p);
	p.sink.put(" then ");
	dumpBranchTargets(p);
}

void dumpBinBranch(ref InstrPrintInfo p)
{
	string[] opStrings = p.settings.escapeForDot ? binaryCondStringsEscapedForDot : binaryCondStrings;
	p.sink.put("    if");
	dumpArg(p.instrHeader.arg(p.ir, 0), p);
	p.sink.putf(" %s", opStrings[p.instrHeader.cond]);
	dumpArg(p.instrHeader.arg(p.ir, 1), p);
	p.sink.put(" then ");

	dumpBranchTargets(p);
}

void dumpBranchTargets(ref InstrPrintInfo p)
{
	switch (p.block.successors.length) {
		case 0:
			p.sink.put(p.settings.escapeForDot ? `\<null\> else \<null\>` : "<null> else <null>");
			break;
		case 1:
			p.sink.putf(p.settings.escapeForDot ? `%s else \<null\>` : "%s else <null>",
				IrIndexDump(p.block.successors[0, p.ir], p));
			break;
		default:
			p.sink.putf("%s else %s",
				IrIndexDump(p.block.successors[0, p.ir], p),
				IrIndexDump(p.block.successors[1, p.ir], p));
			break;
	}
}
