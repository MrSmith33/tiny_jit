/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.stmt.continue_stmt;

import all;


struct ContinueStmtNode {
	mixin AstNodeData!(AstType.stmt_continue, AstFlags.isStatement, AstNodeState.name_resolve_done);
}