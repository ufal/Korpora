#!/usr/bin/env python3
"""Which CoNLL-U comment keys does pando index, and what do the others describe?

Usage: ud-comment-survey.py DIR_WITH_CONLLU INDEX_DIR   (the full table of dropped keys is docs/pando-issue-ud-metadata-keys.csv)
For every comment key the index has no attribute for: lines, files, the share of documents in which the value is
constant (a `# newdoc` starts a document; a file without one is one document) and the share of sentences that carry it.
"""
import re,glob,collections,sys
DATA,INDEX=sys.argv[1],sys.argv[2]
info=open(INDEX+'/corpus.info').read()
attrs=set(re.search(r'region_attrs=(.*)',info).group(1).split(','))
def imported(k):
    if k in('newdoc','newpar','sent_id','text'): return True
    if k.startswith('meta::'): return 'doc_'+k[6:] in attrs
    if k in attrs: return True
    return 's_'+k in attrs and k.startswith('text_')
# per key: units (doc or file), per unit: set of values, number of sentences having key, number of sentences in unit
stat=collections.defaultdict(lambda: dict(lines=0,files=set(),units=0,const_units=0,full_units=0,sent_units=0,fconst=0,fvals=0,distinct=set()))
for f in sorted(glob.glob(DATA+'/**/*.conllu',recursive=True)):
    units=[]; cur=None
    def newunit():
        return dict(sents=0,vals=collections.defaultdict(list))
    cur=newunit(); units.append(cur)
    filevals=collections.defaultdict(set)
    for blk in open(f,encoding='utf-8',errors='replace').read().split('\n\n'):
        lines=[l for l in blk.split('\n') if l.startswith('# ')]
        if not lines: continue
        if any(re.match(r'# newdoc\b',l) for l in lines) and cur['sents']>0:
            cur=newunit(); units.append(cur)
        cur['sents']+=1
        seen=set()
        for l in lines:
            m=re.match(r'# ([^=\s:]+)\s*[=:]\s*(.*)',l)
            if not m: continue
            k,v=m.group(1),m.group(2).strip()
            if imported(k) or k in seen: continue
            seen.add(k); cur['vals'][k].append(v); filevals[k].add(v)
    for u in units:
        for k,vs in u['vals'].items():
            s=stat[k]; s['units']+=1
            if len(set(vs))==1: s['const_units']+=1
            if len(vs)==u['sents']: s['full_units']+=1
            s['files'].add(f)
    for k,vs in filevals.items():
        s=stat[k]; s['fvals']+=1
        if len(vs)==1: s['fconst']+=1
    for u in units:
        for k,vs in u['vals'].items():
            stat[k]['lines']+=len(vs); stat[k]['distinct'].update(vs)
out=[]
for k,s in stat.items():
    out.append(dict(key=k,lines=s['lines'],files=len(s['files']),units=s['units'],const=s['const_units'],full=s['full_units'],fconst=s['fconst'],fvals=s['fvals'],distinct=len(s['distinct'])))
out.sort(key=lambda d:-d['lines'])
print(len(out), "dropped keys")
print("| key | lines | files | constant in a document | on every sentence |")
print("|---|---:|---:|---:|---:|")
for d in out[:40]:
    print(f"| {d['key']} | {d['lines']:,} | {d['files']} | {d['const']/d['units']:.0%} of {d['units']:,} | {d['full']/d['units']:.0%} |")
