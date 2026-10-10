# Formats kernel_bench JSON lines as a markdown table with speedups vs. reference.
# Usage: python3 bench_table.py build/x86_64/bench.jsonl
import sys,json
rows=[json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
ks=[];d={}
for r in rows:
  if r['kernel'] not in ks: ks.append(r['kernel'])
  d[(r['variant'],r['kernel'])]=r['ns_per_elem']
vs=[v for v in ['reference','x86_scalar','x86_avx2','x86_avx512'] if any(k[0]==v for k in d)]
print('| kernel | '+' | '.join(vs)+' | '+' | '.join('%s vs ref'%v for v in vs[1:])+' |')
print('|---'*(2*len(vs))+'|')
for k in ks:
  print('| %s | '%k+' | '.join('%.4f'%d[(v,k)] for v in vs)+' | '+' | '.join('%.2fx'%(d[('reference',k)]/d[(v,k)]) for v in vs[1:])+' |')
