# 把测试版装到自己的 iPhone（没有 Mac）

**只把代码推到 GitHub 还不能安装。** 还要等 GitHub Actions 打出 `GuolemeAI.ipa`，再用 Windows 上的 Sideloadly 装到手机。

## 1. 等云端打出 IPA

1. 打开 https://github.com/ZechangXue/meeting_agent_ios/actions
2. 若提示启用 Actions，先 Enable
3. 选 workflow **iOS IPA** → **Run workflow**
4. 等 macOS 任务变绿（大约 5–15 分钟）
5. 打开这次 run → **Artifacts** → 下载 `GuolemeAI-ipa` → 解压得到 `GuolemeAI.ipa`

私有仓库只有登录你的 GitHub 账号才能下载产物。

## 2. Windows 装到手机（7 天测试）

1. 卸载微软商店版 iTunes / iCloud，改装苹果官网独立版 iTunes
2. 下载安装 [Sideloadly](https://sideloadly.io)
3. USB 连 iPhone；系统提示时打开 **开发者模式**
4. 把 `GuolemeAI.ipa` 拖进 Sideloadly，填你的 Apple ID，点 Start
5. 手机：设置 → 通用 → VPN 与设备管理 → 信任该开发者

免费 Apple ID 大约 **7 天**过期，电脑再打开 Sideloadly 签一次即可。交了年费后改用 TestFlight，不必每周重签。

## 3. 手机要求

- iOS 17 或更高
- 首次打开请允许麦克风
