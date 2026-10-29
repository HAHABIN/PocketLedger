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

# 首次安装启动后切换到内存示例模式，生成首页截图供开发验收。
run('xcrun', 'simctl', 'terminate', device['udid'], 'com.example.PocketLedger')
run('xcrun', 'simctl', 'launch', device['udid'], 'com.example.PocketLedger', '--界面预览')
time.sleep(3)
pathlib.Path('screenshots').mkdir(exist_ok=True)
image = pathlib.Path('screenshots/home.png')
run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', str(image))
run('sips', '-Z', '700', str(image))
print('界面截图开始:' + base64.b64encode(image.read_bytes()).decode('ascii') + ':界面截图结束')
