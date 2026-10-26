#!/usr/bin/env python3
"""Offline identity/scope checks; this is not a smart-contract security audit."""
from pathlib import Path
import hashlib, json, re

ROOT = Path(__file__).resolve().parents[1]

def main():
    manifest = json.loads((ROOT/'release-sha256.json').read_text())
    actual = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
              for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.parts
              and '__pycache__' not in p.parts and p.name!='release-sha256.json'}
    if actual != manifest:
        raise SystemExit('FAIL: release files or hashes differ from the reviewed manifest')
    forbidden = re.compile(r'(^|/)(\.env(?:\..*)?|keystores?|wallets?|secrets|credentials|node_modules|broadcast|logs|backups|genesis-ops)(/|$)|\.(pem|key|p12|pfx|sqlite|db)$',re.I)
    sources = {}
    for p in (ROOT/'compiler-inputs').glob('*.json'):
        obj=json.loads(p.read_text())
        for name,entry in obj['sources'].items():
            path=Path(name)
            if path.is_absolute() or '..' in path.parts:raise SystemExit('FAIL: unsafe source path')
            raw=entry['content'].encode()
            if name in sources and sources[name]!=raw:raise SystemExit('FAIL: conflicting source closure')
            sources[name]=raw
            if (ROOT/'sources'/name).read_bytes()!=raw:raise SystemExit('FAIL: source differs from compiler input')
    for name in actual:
        if forbidden.search(name):raise SystemExit('FAIL: prohibited runtime/credential path')
        content=(ROOT/name).read_text(errors='replace')
        patterns=[r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                  r'\b(?:ghp_|github_pat_|AKIA)[A-Za-z0-9_]{16,}',
                  r'(?im)^\s*(?:PRIVATE_KEY|MNEMONIC|ETH_PASSWORD|DEPLOYER_PRIVATE_KEY|RPC_URL|API_KEY)\s*=\s*\S+']
        if any(re.search(p,content) for p in patterns):raise SystemExit('FAIL: potential credential; value withheld')
    assert len(sources)==51
    assert len(list((ROOT/'compiler-inputs').glob('*.json')))==11
    print('PASS: file manifest; 51 exact sources; 11 compiler inputs; publication scope checks.')
    print('Pattern checks do not prove that arbitrary secrets are absent. No RPC or signing performed.')

if __name__=='__main__':main()
