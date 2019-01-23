/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module ast.declaration;

import all;

mixin template ScopeDeclNodeData(AstType _astType, int default_flags = 0) {
	mixin AstNodeData!(_astType, default_flags | AstFlags.isScope | AstFlags.isDeclaration);
	/// Each node can be struct, function or variable
	AstNode*[] declarations;
}

struct ModuleDeclNode {
	mixin ScopeDeclNodeData!(AstType.decl_module);
	Scope* _scope;
	/// Linear list of all functions of a module (including nested and methods and externals)
	FunctionDeclNode*[] functions;
	IrModule irModule;
	IrModule lirModule;
	ubyte[] code;

	void addFunction(FunctionDeclNode* func) {
		func.backendData.index = FunctionIndex(cast(uint)functions.length);
		functions ~= func;
	}

	FunctionDeclNode* findFunction(string idStr, CompilationContext* ctx) {
		Identifier id = ctx.idMap.find(idStr);
		if (id == uint.max) return null;
		return findFunction(id);
	}
	FunctionDeclNode* findFunction(Identifier id) {
		Symbol* sym = _scope.symbols.get(id, null);
		if (sym.symClass != SymbolClass.c_function) return null;
		return sym.funcDecl;
	}
}

struct StructDeclNode {
	mixin ScopeDeclNodeData!(AstType.decl_struct);
	mixin SymRefNodeData;
	Scope* _scope;
	IrIndex irType;
}

/// Points into ModuleDeclNode.functions
struct FunctionIndex
{
	uint index;
	alias index this;
}

struct FunctionBackendData
{
	/// Machine-independent IR
	IrFunction* irData;
	/// Machine-level IR
	IrFunction* lirData;
	///
	FunctionLiveIntervals* liveIntervals;
	/// Executable machine-code bytes
	ubyte[] code;
	/// Position in buffer or in memory
	void* funcPtr;
	///
	StackLayout stackLayout;
	///
	CallConv* callingConvention;
	/// Callers will use this index to call this function.
	FunctionIndex index;
	/// Index of IrValueKind.type kind
	IrIndex returnType;
	///
	Identifier name;
}

struct FunctionDeclNode {
	mixin AstNodeData!(AstType.decl_function, AstFlags.isDeclaration);
	mixin SymRefNodeData;
	TypeNode* returnType;
	VariableDeclNode*[] parameters;
	BlockStmtNode* block_stmt; // null if external
	Scope* _scope;
	FunctionBackendData backendData;

	/// External functions have no body
	bool isExternal() { return block_stmt is null; }
}

enum VariableFlags : ubyte {
	isParameter        = 1 << 1,
	forceMemoryStorage = 1 << 0,
}

struct VariableDeclNode {
	mixin AstNodeData!(AstType.decl_var, AstFlags.isDeclaration | AstFlags.isStatement);
	mixin SymRefNodeData;
	TypeNode* type;
	ExpressionNode* initializer; // may be null
	ubyte varFlags;
	ushort scopeIndex; // stores index of parameter or index of member (for struct fields)
	IrIndex irValue; // kind is variable or stackSlot, unique id of variable within a function
	bool isParameter() { return cast(bool)(varFlags & VariableFlags.isParameter); }
	bool forceMemoryStorage() { return cast(bool)(varFlags & VariableFlags.forceMemoryStorage); }
}