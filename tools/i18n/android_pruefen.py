#!/usr/bin/env python3
import re,pathlib,sys
ROOT=pathlib.Path("java/app/thisdog")
DIRS=["ui","gassi","system","help","data","model",""]
SKIPFILES={"Day.kt","Content.kt","L.kt","Beispiel.kt","Api.kt","Sealing.kt","KeyVault.kt","RecoveryCode.kt","Theme.kt"}
SKIPBEFORE=re.compile(r'(const val \w+\s*=\s*$|@\w+\(\s*$|(?:getSharedPreferences|getString|getBoolean|getLong|putBoolean|putString|putLong|getStringExtra|getBooleanExtra|getIntExtra|setRequestProperty|URL|api\.post|api\.get|api\.upload|Regex|File|forName|mapOf|obj|parse|startsWith|endsWith|contains|substringAfter|substringBefore|split|replace|Uri\.parse|setType|openPage|Log\.\w+|getInstance|assets\.open|String\.format\(\w+(?:\.\w+)*|SimpleDateFormat|format|error|require|check)\(\s*$)')
def literals(s):
    i=0;n=len(s);out=[]
    while i<n:
        if s.startswith('//',i):
            j=s.find('\n',i); i=n if j<0 else j; continue
        if s.startswith('/*',i): i=s.find('*/',i)+2; continue
        if s.startswith('"""',i): i=s.find('"""',i+3)+3; continue
        if s[i]=="'":
            i+= 4 if s[i+1]=='\\' else 3; continue
        if s[i]=='"':
            j=i+1;parts=[];buf=[]
            segs=[];cur=""
            args=[]
            while s[j]!='"' and s[j]!='\n':
                if s[j]=='\\':
                    cur+=s[j:j+2]; j+=2; continue
                if s[j]=='$' and s[j+1]=='{':
                    k=j+2;d=1;q=False
                    while d>0:
                        c=s[k]
                        if c=='"': q=not q
                        elif not q and c=='{': d+=1
                        elif not q and c=='}': d-=1
                        k+=1
                    args.append(s[j+2:k-1]); cur+="\0"; j=k; continue
                if s[j]=='$' and (s[j+1].isalpha() or s[j+1]=='_'):
                    m=re.match(r'\w+(?:\.\w+)*',s[j+1:]); e=re.match(r'\w+',s[j+1:]).group(0)
                    args.append(e); cur+="\0"; j+=1+len(e); continue
                cur+=s[j]; j+=1
            out.append((i,j+1,cur,args)); i=j+1; continue
        i+=1
    return out
def human(t):
    plain=t.replace("\0","")
    letters=re.sub(r'[^A-Za-zÄÖÜäöüß]','',plain)
    if len(letters)<2: return False
    if re.match(r'^(https?:|/)',plain) or re.fullmatch(r'[a-z_.:\-/0-9]+',plain): return False
    if re.fullmatch(r'[A-Z_0-9]+',plain) or re.fullmatch(r'[a-z]+[A-Z]\w*',plain): return False
    if plain in ('MissingPermission','ThisDog','If-None-Match','ETag','android.content.extra.IS_SENSITIVE','d. MMMM yyyy','d. MMM, HH:mm'): return False
    if re.search(r'[{}<>=]|\bSELECT\b|application/|\.json|\.jpg|\\u',plain): return False
    if plain.startswith('%') and ' ' not in plain: return False
    return bool(re.search(r'[A-ZÄÖÜäöüß]| ',plain))
tot=0;rows=[]
for f in ROOT.rglob("*.kt"):
    if f.name in SKIPFILES or 'i18n' in f.parts or f.parent.name not in ("ui","gassi","system","help","data","model"): continue
    s=f.read_text();edits=[]
    for a,b,cur,args in literals(s):
        if not human(cur): continue
        before=s[max(0,a-60):a]
        if SKIPBEFORE.search(before): rows.append(('skip',f.name,s[a:b][:80])); continue
        line=s[s.rfind('\n',0,a)+1:a]
        if re.search(r'^\s*(package|import)\b',line) or 'Sym' in line and 'const' in line: continue
        if re.search(r'L\.t\(\s*$',before): continue
        if '"' in "".join(args) and any('"' in x for x in args): rows.append(('nested',f.name,s[a:b][:100])); pass
        src=cur.replace('%','%%') if args else cur
        n=0
        def rep(m):
            global n
            n_=rep.i; rep.i+=1
            return f'%{n_}$s'
        rep.i=1
        src=re.sub('\0',rep,src).replace('$','\\$') if args else cur.replace('$','\\$') if False else (re.sub('\0',rep,src).replace('$','\\$') if args else cur)
        new='L.t("'+src+'"'+''.join(', '+x for x in args)+')'
        edits.append((a,b,new)); rows.append(('wrap',f.name,new[:100]))
    if '--apply' in sys.argv and edits:
        for a,b,new in reversed(edits): s=s[:a]+new+s[b:]
        if 'import app.thisdog.i18n.L' not in s:
            m=re.search(r'^import ',s,re.M); s=s[:m.start()]+'import app.thisdog.i18n.L\n'+s[m.start():] if m else re.sub(r'^(package .*\n)',r'\1\nimport app.thisdog.i18n.L\n',s,count=1,flags=re.M)
        f.write_text(s)
from collections import Counter
print(Counter(r[0] for r in rows))
if len(sys.argv)>1 and not sys.argv[1].startswith('--'):
    for r in rows:
        if r[0]==sys.argv[1]: print(r[1],r[2])
