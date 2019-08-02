/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.decl.module_;

import all;

/// Index into CompilationContext.files
struct ModuleIndex
{
	uint fileIndex;
}

///
struct ModuleDeclNode {
	mixin ScopeDeclNodeData!(AstType.decl_module);
	Scope* _scope;
	/// Linear list of all functions of a module (including nested and methods and externals)
	Array!(FunctionDeclNode*) functions;
	IrModule irModule;
	IrModule lirModule;
	LinkIndex objectSymIndex;
	ModuleIndex moduleIndex;
	/// module identifier. Used by import declaration.
	Identifier id;

	void addFunction(ref ArrayArena arrayArena, FunctionDeclNode* func) {
		func.backendData.index = FunctionIndex(cast(uint)functions.length, moduleIndex);
		functions.put(arrayArena, func);
	}

	FunctionDeclNode* findFunction(string idStr, CompilationContext* ctx) {
		Identifier id = ctx.idMap.find(idStr);
		if (id.isUndefined) return null;
		return findFunction(id);
	}
	FunctionDeclNode* findFunction(Identifier id) {
		AstNode* sym = _scope.symbols.get(id, null);
		if (sym is null) return null;
		return sym.cast_decl_function;
	}
}

void name_register_module(ModuleDeclNode* node, ref NameRegisterState state) {
	node.state = AstNodeState.name_register;
	node._scope = state.pushScope("Module", No.ordered);
	foreach (decl; node.declarations) require_name_register(decl, state);
	state.popScope;
	node.state = AstNodeState.name_register_done;
}

void name_resolve_module(ModuleDeclNode* node, ref NameResolveState state) {
	state.pushScope(node._scope);
	foreach (decl; node.declarations) require_name_resolve(decl, state);
	state.popScope;
	node.state = AstNodeState.name_resolve_done;
}