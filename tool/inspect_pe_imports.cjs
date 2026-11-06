// Read-only PE import inventory. Does not load or execute the DLL.
const fs = require('node:fs');
const crypto = require('node:crypto');
const file = process.argv[2];
if (!file) throw new Error('Usage: node inspect_pe_imports.cjs path-to-dll');
const b = fs.readFileSync(file);
const pe = b.readUInt32LE(0x3c);
if (b.readUInt32LE(pe) !== 0x4550) throw new Error('Not a PE image');
const sections = b.readUInt16LE(pe + 6);
const optional = pe + 24;
const magic = b.readUInt16LE(optional);
if (![0x20b, 0x10b].includes(magic)) throw new Error('Unknown optional header');
const sectionStart = optional + b.readUInt16LE(pe + 20);
function offset(rva) {
  for (let i = 0; i < sections; i++) {
    const s = sectionStart + i * 40;
    const start = b.readUInt32LE(s + 12);
    const size = Math.max(b.readUInt32LE(s + 8), b.readUInt32LE(s + 16));
    if (rva >= start && rva < start + size) return b.readUInt32LE(s + 20) + rva - start;
  }
  throw new Error('RVA outside sections');
}
const directory = optional + (magic === 0x20b ? 112 : 96);
const rva = b.readUInt32LE(directory + 8);
const imports = [];
if (rva) {
  const start = offset(rva);
  for (let i = 0; i < 4096; i++) {
    const descriptor = start + i * 20;
    const name = b.readUInt32LE(descriptor + 12);
    if (!name) break;
    const begin = offset(name);
    const end = b.indexOf(0, begin);
    if (end < begin || end - begin > 4096) throw new Error('Invalid import name');
    imports.push(b.toString('ascii', begin, end));
  }
}
console.log(JSON.stringify({file, sha256: crypto.createHash('sha256').update(b).digest('hex'), imports,
  limitations: 'Normal PE imports only; does not enumerate delay/dynamic loads or prove every dependency feature.'}, null, 2));
