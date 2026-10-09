const fs=require('fs'),lp=require('luaparse');
for (const f of process.argv.slice(2)) { try { lp.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.1'}); console.log('OK  ',f);} catch(e){ console.log('FAIL',f,e.message); process.exitCode=1; } }
