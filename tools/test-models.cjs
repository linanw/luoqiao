// Run portable ArkTS model tests with the TypeScript bundled in DevEco Studio.
const fs = require('fs');
const path = require('path');
const devEco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(devEco, 'tools/ohpm/node_modules/typescript'));
function compile(module, filename) {
  const source = fs.readFileSync(filename, 'utf8');
  const result = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename });
  module._compile(result.outputText, filename);
}
require.extensions['.ets'] = compile;
require.extensions['.ts'] = compile;
for (const name of ['WireGuardConfig', 'DomainRules']) {
  require(path.join(__dirname, '..', 'tests', name + '.test.ts'));
  console.log(name + ': passed');
}
