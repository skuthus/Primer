// Report identifiers that resolve to globals, by walking the finished AST with scope info.
const fs=require('fs'),lp=require('luaparse');
const ok=new Set(['G_reader_settings','G_defaults','math','string','os','table','pairs','ipairs','tostring','tonumber','require','pcall','xpcall','type','print','next','select','error','assert','unpack','setmetatable','getmetatable','rawget','rawset','coroutine','io','debug','dofile','bit','jit']);
let bad=false;
for (const f of process.argv.slice(2)) {
  const ast=lp.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.1',scope:true,locations:true});
  const found=new Set();
  (function walk(n){ if(!n||typeof n!=='object')return; if(Array.isArray(n)){n.forEach(walk);return;}
    if(n.type==='Identifier'&&n.isLocal===false&&!ok.has(n.name)) found.add(n.name+':'+n.loc.start.line);
    for(const k in n) if(k!=='loc'&&k!=='range') walk(n[k]); })(ast);
  if(found.size) bad=true;
  console.log(f.split('/').pop(), found.size? 'GLOBALS: '+[...found].join(', ') : 'no unknown globals');
}
process.exitCode=bad?1:0;
