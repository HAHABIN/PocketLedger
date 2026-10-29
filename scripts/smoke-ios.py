"""启动可用的 iPhone 模拟器，安装并打开离线记账应用。"""
import json
import pathlib
import subprocess
import time
import base64

def run(*args):
    return subprocess.check_output(args, text=True)

inventory = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))
candidates = [device for runtime, devices in inventory['devices'].items() if 'iOS' in runtime for device in devices if device['name'].startswith('iPhone') and device.get('isAvailable')]
if not candidates:
    raise SystemExit('没有可用的 iPhone 模拟器')
device = candidates[0]
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', device['udid'])
run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
app = pathlib.Path('build/Build/Products/Debug-iphonesimulator/PocketLedger.app')
run('xcrun', 'simctl', 'install', device['udid'], str(app))
print(run('xcrun', 'simctl', 'launch', device['udid'], 'com.example.PocketLedger'))

# 仅使用内存样例逐屏截图，正式数据库不写入示例交易。
pathlib.Path('screenshots').mkdir(exist_ok=True)
for page, flag in [('home', None), ('reports', '--预览报表'), ('assets', '--预览资产'), ('books', '--预览账本'), ('entry', '--预览记账'), ('data', '--预览数据管理')]:
    subprocess.run(['xcrun', 'simctl', 'terminate', device['udid'], 'com.example.PocketLedger'], check=False)
    args = ['xcrun', 'simctl', 'launch', device['udid'], 'com.example.PocketLedger', '--界面预览']
    if flag:
        args.append(flag)
    run(*args)
    time.sleep(15)
    image = pathlib.Path('screenshots') / (page + '.png')
    run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', str(image))
    run('sips', '-Z', '800', str(image))
    print('截图_' + page + ':' + base64.b64encode(image.read_bytes()).decode('ascii') + ':截图结束')

# 校验专用文件类型已注册，不依赖连接服务器或真实账户。
import plistlib
with (app / 'Info.plist').open('rb') as file:
    info = plistlib.load(file)
assert any('com.localbookkeeping.backup' in item.get('LSItemContentTypes', []) for item in info.get('CFBundleDocumentTypes', []))
assert any('pocketledger' in item.get('UTTypeTagSpecification', {}).get('public.filename-extension', []) for item in info.get('UTExportedTypeDeclarations', []))
subprocess.run(['xcrun', 'simctl', 'terminate', device['udid'], 'com.example.PocketLedger'], check=False)
run('xcrun', 'simctl', 'launch', device['udid'], 'com.example.PocketLedger', '--界面预览', '--备份文件自检')
container = pathlib.Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], 'com.example.PocketLedger', 'data').strip())
report = container / 'Documents/backup-self-check.txt'
for _ in range(45):
    if report.exists():
        result = report.read_text()
        print(result)
        assert result.startswith('PASS'), result
        break
    time.sleep(1)
else:
    raise AssertionError('备份文件自检超时')
