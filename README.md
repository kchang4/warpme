# WarpMe

An Ashita v4 addon that warps you home using the fastest available method.

## Usage

```
/warpme
```

## Priority Order

WarpMe checks for warp methods in this order and uses the first one available:

1. **Warp Spell** - If you can cast it on your current job/sub and it's off recast
2. **Equipment** - Warp Cudgel, Warp Ring, etc. if ready to use
3. **Instant Warp** - Consumes a scroll from inventory as last resort

## Supported Equipment

- Warp Cudgel
- Warp Ring
- Tavnazian Ring
- Stars Cap
- Maat's Cap
- Trick Staff II
- Treat Staff II

## Features

- Automatically equips warp items and waits for equip delay
- Checks spell level requirements against your current job/sub
- Shows cooldown status when nothing is available
- Countdown timer while waiting for equipment delay

## Installation

Place the `warpme` folder in your Ashita `addons` directory and load with:

```
/addon load warpme
```
