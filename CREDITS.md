# 素材与第三方授权

## 背景图

| 文件 | 来源 | 作者 | 授权 |
|---|---|---|---|
| `entry/src/main/resources/base/media/bg_pillars.jpg` | ESA/Hubble，`heic1501a` | NASA, ESA, and the Hubble Heritage Team (STScI/AURA) | **CC BY 4.0** |

原图：<https://esahubble.org/images/heic1501a/>

CC BY 4.0 要求署名。若你在自己的分发中使用本项目的背景图，
请保留上述署名信息，或在「关于」页面展示。

## 运行时依赖的华为服务

本应用调用以下 HarmonyOS 系统能力，均不属于本仓库，遵循华为各自的许可：

| 能力 | 用途 |
|---|---|
| Map Kit（花瓣地图） | 显示暗夜地点，需要 AGC 开通「地图服务」 |
| Location Kit | 城市级/精确位置 |
| ArkData preferences | 本地反馈记录 |
| Weather Kit | **尚未接入** |

## 字体与图标

当前使用系统默认字体；Dock 只有文字标签，未使用自定义图标。
