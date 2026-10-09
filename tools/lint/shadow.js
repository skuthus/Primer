// Flag any local binding named "_" (loop vars, params, locals): it would shadow gettext's _().
const fs=require('fs'),lp=require('luaparse'); let bad=false;
for (const f of process.argv.slice(2)) {
  const ast=lp.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.1',locations:true}); const hits=[];
  (function walk(n,top){ if(!n||typeof n!=='object')return; if(Array.isArray(n)){n.forEach(x=>walk(x,top));return;}
    const names=[...(n.variables||[]),...(n.parameters||[])].filter(v=>v&&v.type==='Identifier'&&v.name==='_');
    const isTopGettext = n.type==='LocalStatement'&&top&&n.init&&n.init[0]&&n.init[0].type==='CallExpression';
    if((n.type==='ForGenericStatement'||n.type==='ForNumericStatement'||n.type==='FunctionDeclaration'||n.type==='LocalStatement')&&!isTopGettext) names.forEach(v=>hits.push(v.loc.start.line));
    for(const k in n) if(k!=='loc') walk(n[k], n.type==='Chunk'); })(ast,true);
  if(hits.length) bad=true;
  console.log(f.split('/').pop(), hits.length?'SHADOWS _ at lines '+hits.join(','):'no _ shadowing');
}
process.exitCode=bad?1:0;
