#!/usr/bin/env python3
"""Findet Swift-Stringliterale. --apply wickelt nutzertexte außerhalb von LocalizedStringKey-Stellen in String(localized:)."""
import re,sys,pathlib
ROOTS=["ThisDog","ThisDogWatch","ThisDogWidgets","Shared"]
SKIPDIR=("Resources",)
KEY=re.compile(r'(?:\b(?:Text|Button|Label|TextField|SecureField|Toggle|Picker|Section|NavigationLink|Link|LabeledContent|Menu|DatePicker|Stepper|ContentUnavailableView|ShareLink|TextEditor)\(\s*$)|(?:\.(?:navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog|help)\(\s*$)')
SKIPCTX=re.compile(r'(systemImage|systemName|forKey|named|forResource|withExtension|name|format|identifier|key|kind|id|host|scheme|path|action|method|subsystem|category|prefix|hasPrefix|hasSuffix|contains|service|account|pack|query|header|type|code|value|environment|forHTTPHeaderField|dateFormat|withTemplate|of|with|separator|in):\s*$')
def literals(s):
    i=0;n=len(s);out=[]
    while i<n:
        c=s[i]
        if s.startswith('//',i): i=s.find('\n',i); i=n if i<0 else i; continue
        if s.startswith('/*',i): i=s.find('*/',i)+2; continue
        if s.startswith('"""',i): i=s.find('"""',i+3)+3; continue
        if c=='"':
            j=i+1;depth=0
            while j<n:
                if s[j]=='\\' and s[j+1]=='(': depth+=1; j+=2; continue
                if depth>0:
                    if s[j]=='(': depth+=1
                    elif s[j]==')': depth-=1
                    elif s[j]=='"':
                        j+=1
                        while s[j]!='"':
                            j+= 2 if s[j]=='\\' else 1
                    j+=1; continue
                if s[j]=='\\': j+=2; continue
                if s[j]=='"': break
                if s[j]=='\n': break
                j+=1
            out.append((i,j+1)); i=j+1; continue
        i+=1
    return out
def human(t):
    b=t[1:-1]
    plain=re.sub(r'\\\((?:[^()]|\([^()]*\))*\)','',b)
    letters=re.sub(r'[^A-Za-zÄÖÜäöüß]','',plain)
    if len(letters)<2: return False
    if re.match(r'^(https?:|[a-z_.\-/]+$|[a-z0-9]+[A-Z])',plain): return False
    if re.fullmatch(r'[a-z_.:\-/%0-9 ]+',plain) and ' ' not in plain: return False
    if '%' in plain and ' ' not in plain: return False
    if re.fullmatch(r'[A-Za-z]+\.[a-zA-Z.]+',plain): return False
    return bool(re.search(r'[A-ZÄÖÜ]|[äöüß]| ',plain)) and not re.fullmatch(r'[A-Z_]+',plain)
tot={};rows=[]
for r in ROOTS:
    for f in pathlib.Path(r).rglob('*.swift'):
        if f.name in ('DayText.swift','AppLocale.swift','NearbySheet_x'): continue
        s=f.read_text();lits=literals(s);edits=[]
        for a,b in lits:
            t=s[a:b]
            if not human(t): continue
            before=s[max(0,a-70):a]
            line=s[s.rfind('\n',0,a)+1:a]
            if 'case ' in line and re.match(r'\s*case\b',line) and not re.search(r'return|:\s*$|=\s*$',line): rows.append(('pattern',f,t)); continue
            if KEY.search(before): continue
            if SKIPCTX.search(before): rows.append(('skipctx',f,t)); continue
            if re.search(r'String\(localized:\s*$|verbatim:\s*$|print\($|fatalError\($|#expect\(|Logger',before): continue
            edits.append((a,b)); rows.append(('wrap',f,t))
        if '--apply' in sys.argv and edits:
            for a,b in reversed(edits): s=s[:a]+'String(localized: '+s[a:b]+')'+s[b:]
            f.write_text(s)
from collections import Counter
print(Counter(r[0] for r in rows))
for k,f,t in rows:
    if k==sys.argv[1] if len(sys.argv)>1 and not sys.argv[1].startswith('--') else False: print(k,f,t[:90])
