"""Build and validate a Lua-only Bingus Shared Loader package; never deploys."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import uuid
import zipfile
from lua_vm import LuaVM

ROOT = Path(__file__).resolve().parents[1]
NAME = 'mods/tyhh10/room_steam_info'
GUID = '626b491b-3319-4b9a-91ad-63bd56815260'
VERSION = '0.2.2'
ARCHIVE = '9ba626afa44a3aa3.patch_0'
TYPE = 0xA14E8DFA2CD117E2


def resource_hash(name):
    """Seed-zero MurmurHash64A used by the engine resource name."""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def make_archive(source):
    payload = struct.pack('<II', len(source), 2) + source
    offset = 192
    length = (offset + len(payload) + 15) & ~15
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, 1, b'', length, 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, TYPE, 1, 0, 16, 16)
    entry = struct.pack('<7Q6I', resource_hash(NAME), TYPE, offset, 0, 0, 0, 0, len(payload), 0, 0, 16, 16, 0)
    return (header+types+entry).ljust(offset,b'\0') + payload + b'\0'*(length-offset-len(payload))


def bundle(spec):
    lines = [f'-- HD2-Addon: {NAME}\n', 'local Spec = {\n']
    for key in ('context','roster','local_peer','peer_count','peers','engine_root'):
        lines.append(f'{key}={spec[key]},\n')
    for key in ('game','exe','steam'):
        mod = spec[key]
        lines.append(f'{key}={{timestamp={mod["timestamp"]},size={mod["size"]},proofs={{\n')
        for proof in mod.get('proofs',[]):
            escaped = ''.join('\\'+str(b) for b in bytes.fromhex(proof['hex']))
            lines.append(f'{{rva={proof["rva"]},bytes="{escaped}"}},\n')
        lines.append('}},\n')
    lines.append('}\n')
    ui=spec.get('ui')
    if ui:
        lines.append('Spec.ui={\n')
        for key in ('menu','font','atlas','material'): lines.append(f'{key}={ui[key]},\n')
        lines.append('proofs={\n')
        for proof in ui.get('proofs',[]):
            escaped=''.join('\\'+str(b) for b in bytes.fromhex(proof['hex']))
            lines.append(f'{{rva={proof["rva"]},bytes="{escaped}"}},\n')
        lines.append('}}\n')
    for variable, path in [('Identity','identity.lua'),('Native','native.lua'),('Desktop','desktop.lua'),('Panel','panel.lua')]:
        lines += [f'local {variable}=(function()\n',(ROOT/'src'/path).read_text(encoding='utf-8'),'\nend)()\n']
    lines.append((ROOT/'src/main.lua').read_text(encoding='utf-8'))
    return ''.join(lines).encode('utf-8')


def verify_inputs(game, spec):
    hashes = {}
    for name, relative in [('game','data/game/game.dll'),('exe','bin/helldivers2.exe'),('steam','bin/steam_api64.dll')]:
        data = (game/relative).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != spec[name]['sha256']:
            raise ValueError(f'{relative}: unsupported SHA-256 {digest}')
        pe = struct.unpack_from('<I',data,0x3c)[0]
        stamp = struct.unpack_from('<I',data,pe+8)[0]
        size = struct.unpack_from('<I',data,pe+80)[0]
        if stamp != spec[name]['timestamp'] or size != spec[name]['size']:
            raise ValueError(f'{relative}: PE stamp or image size mismatch')
        # game.dll's executable sections are unpacked only in the live process.
        # Disk fingerprints validate the build; Lua verifies loaded code proofs.
        hashes[relative] = digest
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game',type=Path,required=True)
    args = parser.parse_args()
    spec=json.loads((ROOT/'config/build-25480438.json').read_text())
    hashes=verify_inputs(args.game,spec)
    build=ROOT/'build';build.mkdir(exist_ok=True)
    source=bundle(spec)
    vm=LuaVM(args.game/'bin/lua51.dll')
    try:
        vm.load(source,'@hd2_room_steam_info')
        vm.api.lua_settop(vm.state,0)
        for path in sorted((ROOT/'tests').glob('test_*.lua')):
            vm.run(path.read_bytes(),'@'+path.name)
    finally:
        vm.close()
    test_result=build/'test-result.json'
    try:
        parsed=json.loads(test_result.read_text(encoding='utf-8'))
        assert len(parsed['members'])==1 and parsed['self_excluded'] is True
    finally:
        test_result.unlink(missing_ok=True)
    (build/'room_steam_info.lua').write_bytes(source)
    archive=make_archive(source)
    resource_offset=struct.unpack_from('<Q',archive,120)[0]
    resource_length=struct.unpack_from('<I',archive,160)[0]
    payload=archive[resource_offset:resource_offset+resource_length]
    assert payload==struct.pack('<II',len(source),2)+source
    assert source.startswith((f'-- HD2-Addon: {NAME}\n').encode()) and len(source.splitlines()[0])<256
    uuid.UUID(GUID)
    description='Esc 游戏页小队右侧显示队友平台、SteamID64 和主页，点击主页复制链接；支持文件导出。需要 Bingus Shared Loader v15+ / API 1。'
    manifest={'Version':1,'Guid':GUID,'Name':'HD2 Room Steam Info '+VERSION,'Description':description,
              'Options':[{'Name':'Room Steam Info','Description':description,'Include':['Addon']}]}
    files={'manifest.json':(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode(),
           'Addon/'+ARCHIVE:archive,'Addon/'+ARCHIVE+'.stream':b'','Addon/'+ARCHIVE+'.gpu_resources':b'',
           'README.md':(ROOT/'README.md').read_bytes(),
           'docs/evidence.md':(ROOT/'docs/evidence.md').read_bytes(),
           'docs/lua-ui-guide.md':(ROOT/'docs/lua-ui-guide.md').read_bytes(),
           'THIRD-PARTY.md':(ROOT/'THIRD-PARTY.md').read_bytes()}
    out=ROOT/'dist';out.mkdir(exist_ok=True)
    target=out/f'HD2-Room-Steam-Info-{VERSION}.zip'
    with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for name,data in sorted(files.items()):
            info=zipfile.ZipInfo(name,(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644<<16;z.writestr(info,data)
    digest=hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_suffix('.zip.sha256').write_text(f'{digest}  {target.name}\n')
    (build/'build-report.json').write_text(json.dumps({'game_build':spec['build'],'input_hashes':hashes,
        'package':target.name,'sha256':digest,'validation':'game Lua VM syntax; identity, native, entry, panel and desktop tests; JSON parse; archive round trip',
        'in_game_mod_loaded':False},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(target)
    print('SHA256',digest)


if __name__=='__main__':
    main()
