#!/usr/bin/env python3
"""Compare compiler templates/metadata with the public reviewed artifact."""
from pathlib import Path
import argparse, json

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('contract');p.add_argument('output',type=Path);a=p.parse_args()
    root=Path(__file__).resolve().parents[1]
    artifact=json.loads((root/'artifacts'/(a.contract+'.json')).read_text())
    raw=a.output.read_text();start=raw.find('{')
    if start<0:raise SystemExit('FAIL: no compiler JSON')
    output=json.loads(raw[start:])
    errors=[e for e in output.get('errors',[]) if e.get('severity')=='error']
    if errors:raise SystemExit('FAIL: compiler errors present')
    matches=[v for contracts in output.get('contracts',{}).values() for name,v in contracts.items() if name==a.contract]
    if len(matches)!=1:raise SystemExit('FAIL: contract is not unique in output')
    c=matches[0]
    for field in ('bytecode','deployedBytecode'):
        wanted=artifact[field]['object'].removeprefix('0x')
        got=c['evm'][field]['object'].removeprefix('0x')
        if wanted!=got:raise SystemExit('FAIL: '+field+' template differs')
    if c.get('metadata')!=artifact['rawMetadata']:
        raise SystemExit('FAIL: compiler metadata differs from reviewed candidate artifact')
    print('PASS: creation/runtime templates and metadata match the reviewed artifact for '+a.contract)
    if a.contract=='GenesisV52Oracle':
        print('Oracle candidate matches; original on-chain metadata remains unresolved (Sourcify match, not exact_match).')
    print('On-chain full runtime comparison still requires correct immutable and library-self-address substitution.')

if __name__=='__main__':main()
