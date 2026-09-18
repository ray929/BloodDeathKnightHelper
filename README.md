# Blood Death Knight Helper

A World of Warcraft retail addon for Blood Death Knights.

It watches the two timers a Blood DK lives by — how much **Bone Shield** has
left, and the **Blood Boil** echo about to land — and calls them out with a
voice line, red text on screen, and a pulsing icon mask.

Everything it reads comes from Blizzard's built-in **Cooldown Manager** and from
your own casts, so it keeps working inside dungeons and raids. Other classes and
specs are left alone — the addon simply idles.

## Features

**Bone Shield / Ossuary reminder**

- When Bone Shield appears, a 30-second countdown starts. With about 5 seconds
  left you get a voice callout, the text **Bone Shield expiring!** across the upper
  part of the screen, and a pulsing red mask over the Bone Shield icon in your
  Cooldown Manager.
- It also calls out when Bone Shield actually falls off, and when **Ossuary**
  (Bone Shield at 5+ stacks) drops.
- Each of the three alerts has its own line on screen — and on a Chinese client
  its own voice line too, so you can tell at a glance which one fired.
- Casting Marrowrend, Death's Caress, Death Grip, Gorefiend's Grasp or Dancing Rune
  Weapon clears the warning at once — you just refreshed it.
- Triggers that land within 2 seconds of each other only make one sound.
- If Bone Shield / Ossuary cannot be found in your Cooldown Manager, a yellow line
  stays on screen reminding you to drag them in.
- Text and the icon mask are always on; the voice can be switched off.

**Blood Boil echo countdown**

- Blood Boil lights up → that cast is empowered, and an echo lands 3 seconds
  later. A red bar counts those 3 seconds down.
- The proc window itself is shown as a blue bar (15 seconds) while no echo is
  pending; a golden marquee runs along the red bar whenever your next Blood Boil
  is already empowered.
- The bar floats anywhere on screen: open the preview, then right-drag it into
  place.
- The countdown numbers can be hidden, and the bar can be made narrower or wider.

## Requirements

- Retail client (Interface 120100). No other addon required.
- The Bone Shield reminder needs **Bone Shield** and **Ossuary** placed in your
  Cooldown Manager.

## Installation

Copy the `BloodDeathKnightHelper` folder into
`World of Warcraft\_retail_\Interface\AddOns\`, then restart the client
(or type `/reload` if you are already in game).

## Slash commands

Type `/bdk` on its own to print the list in game.

| Command | What it does |
|---|---|
| `/bdk` | Show the command list |
| `/bdk bs test [1\|2\|3]` | Play one alert (text + voice + icon mask): 1 bone shield down, 2 not enough stacks, 3 expiring — so you can check your setup |
| `/bdk bs sound` | Toggle the Bone Shield voice on / off |
| `/bdk bs sound on\|off` | Turn the voice on / off explicitly |
| `/bdk bp test` | Show the Blood Boil bar for previewing — right-drag to move it, run it again to finish |
| `/bdk bp width <20-400>` | Set the bar width; values outside the range are clamped |
| `/bdk bp text` | Toggle the countdown numbers on the bar |
| `/bdk bp text on\|off` | Show / hide the countdown numbers explicitly |

The addon speaks the language of your game client: Chinese client, Chinese
messages; anything else, English.

## Credits

- **[KiraUI-Plugin](https://www.curseforge.com/wow/addons/kiraui-plugin)** by
  Kiratank — the Blood Boil echo bar is a port of its Boiling Point module, pixel
  marquee glow included. Many thanks.

---

# 鲜血死亡骑士辅助

World of Warcraft 正式服插件，供鲜血死亡骑士使用。

它盯着血 DK 最要紧的两件事 —— **骨盾**还剩多久、**血沸**的回声什么时候落地 ——
用语音、屏幕红字和图标脉冲蒙版一起提醒你。

读数全部来自暴雪自带的**冷却管理器**和你自己的施法事件，因此在副本里照常工作。
其他职业和专精不受影响，插件会自动待机。

## 功能介绍

**骨盾 / 埋骨之所提醒**

- 骨盾出现即开始 30 秒倒计时。约剩 5 秒时，语音提示、屏幕上方的红字
  **补骨盾**、以及冷却管理器里骨盾图标的红色脉冲蒙版一起出现。
- 骨盾真的掉了、或者 **埋骨之所**（骨盾 ≥ 5 层）消失时，同样提醒一次。
- 三条提醒各有各的说法（中文客户端还各有各的语音），一眼/一耳就能分清是哪一条：
  「骨盾没了」「骨盾层数不够」「骨盾快没了」。
- 施放骨髓打击、死神的抚摩、死亡之握、血魔之握、符文刃舞会立刻撤销提醒 —— 你已经补上了。
- 2 秒内接连成立的几次触发只响一声，不重复吵。
- 如果冷却管理器里找不到骨盾 / 埋骨之所，屏幕常驻一行黄字提醒你去把它们拖进去。
- 文字和图标蒙版常开，语音可以关掉。

**血沸回声倒计时**

- 血沸图标发光 ⇒ 这一发是强化版，3 秒后会有回声落地。红色进度条走完这 3 秒。
- 没有回声待落地时，蓝色条显示触发窗口还剩多少（15 秒）；下一发血沸已经攒好时，
  红条上会跑起金色跑马灯。
- 进度条位置随意：打开预览后右键拖动即可。
- 条上的倒计时数字可以藏起来，条本身也能调窄调宽。

## 使用前提

- 正式服（Interface 120100），不需要任何其他插件。
- 骨盾提醒需要在**冷却管理器**里放上「骨盾」和「埋骨之所」两个图标。

## 安装

把 `BloodDeathKnightHelper` 文件夹整个放进
`World of Warcraft\_retail_\Interface\AddOns\`，重启客户端即可
（已经在游戏里就输入 `/reload`）。

## 斜杠命令

游戏里直接输入 `/bdk` 会打印这份列表。

| 命令 | 作用 |
|---|---|
| `/bdk` | 显示命令列表 |
| `/bdk bs test [1\|2\|3]` | 试听某一条提醒（红字 + 语音 + 图标蒙版）：1 骨盾没了、2 骨盾层数不够、3 骨盾快没了，用来检查配置 |
| `/bdk bs sound` | 切换骨盾语音开关 |
| `/bdk bs sound on\|off` | 明确打开 / 关闭语音 |
| `/bdk bp test` | 显示血沸条以便预览 —— 右键拖动定位，再执行一次结束 |
| `/bdk bp width <20-400>` | 设置条的宽度，超出范围会被夹回 |
| `/bdk bp text` | 切换条上是否显示倒计时数字 |
| `/bdk bp text on\|off` | 明确显示 / 隐藏倒计时数字 |

界面语言跟随客户端：中文客户端说中文，其他说英文。

## 致谢

- **[KiraUI-Plugin](https://www.curseforge.com/wow/addons/kiraui-plugin)**（作者
  Kiratank）—— 本插件的血沸回声条移植自它的 Boiling Point 模块，像素跑马灯辉光
  也一并搬了过来。非常感谢。
