# Multi 锁定挖矿
## VE (ve.sol)

Vote escrow (名字待定)，是一种 NFT，借鉴了 solidly ve

主要功能是锁定 Multi(ERC20), 获得 ve(NFT), 计算 ve 的 vote power

对 Multi 来说，vote power 可以称为 weight，作为分手续费的依据

`create_lock` 和 `create_lock_for` 锁定 Multi 创建 ve

LockedBalance 记录锁定的数量和结束时间, ve 和 LockedBalance 一一对应

`balanceOfNFT` 计算 ve 的 vote power，是按时间线性降低到 0 的

`balanceOfNFTAt` 计算某个块高上的 vote power, **不能查询历史块高的 vote power**

`point_history` 和 `user_point_history` 记录了全局和每个 ve 的历史记录，对齐到 week，可以计算每个历史块高上的 `balanceOfNFT`

`user_point_epoch` 记录了 ve 最新的 epoch，每个 ve 的 epoch 都和 全局的 epoch 无关

point 记录了偏移量 bias 和斜率 slope，还有块高和时间戳，point 是根据 LockedBalance 计算的

偏移量表示记录点上的 vote power 的值

斜率是每秒下降的 vote power，斜率等于 vote 锁定余额/剩余时间

计算历史 vote power 时，先找到最近的 point，用 point 中记录的 bias 和 slope 来计算精确的 vote power

```
balanceOfNFT = lastpoint.bias - slope * （block time - lastpoint.time）
```

`increase_amount` 增加数量

`increase_unlock_time` 延长锁定时间

`withdraw` 在锁定期结束后提出 Multi

`merge` 合并同一个 owner 的两个 ve

`deposit`, `increase_amount`, `increase_unlock_time`, `merge`，`withdraw` 都会执行 `_checkpoint`，更新 token owner 自己和全局的记录

`_checkpoint` 根据 old LockedBalance 和 new LockedBalance 更新 `point_history` 和 `user_point_history`

`totalSupply` 计算当前区块的总 vote power，**不是 NFT 的总个数，不是典型的 ERC721**

`totalSupplyAt` 计算历史上某个块高的总 vote power, **不能查询历史块高的 total vote power**

`totalSupplyAtT` 计算某个时刻的总 vote power, **不能查询历史上的 total vote power**

voter 这块功能不需要

    `voter` 是指 voter 合约，voter 合约有权设置 `voted`，`voted` 表示 tokenId 是否正在投票，正在投票的 NFT 不能转账



## 奖励合约
### 1. 按照 ve 分配
每个周期设置 claimPowerDeadline, referenceTime, bonusTime  
$claimPowerDeadline < referenceTime$ (必须严格小于)  
$referenceTime < bonusTime$  
奖励合约记录每个 ve 的 vote power 和总的 vote power

ve owner 需要在 claimPowerDeadline 之前 claimPower, 可以多次 claimPower  
$power = balanceOfNFTAt(tokenId, referenceTime)$  
同时更新 $totalPower = totalPower_{prev} + power$

bonusTime 到了后可以 claim 奖励  
占比是
$$
portion = \frac{power}{totalPower}
$$

*缺点*
- 多一次 claimPower 操作

### 2. master chef + reward ticket
没有 NFT  
每个锁定期发行一个特殊 ERC20 reward ticket token  
每秒奖励固定 ticket  
reward ticket 不用 transfer, 直接 mint, 没有 allocPoint

记录每股累积奖励 accTicketPerShare  
记录每个用户存入的 ERC20 数量和债务  
用户的债务等于 deposit 数量乘以 deposit 之前的每股累积奖励  
havest 领取奖励，$reward = user.amount \times accTicketPerShare - user.debt$  

每期结束后，用户把 ERC20 提出，再存到下一期的池子里

锁定期结束后按照 ticket 所占份额分真正的奖励（USDT）

- 随时可以 harvest 收取 ticket
- convert 必须等到 convert time
- withdraw 必须等到 lock end 取回 Multi
- 允许 emergency withdraw, 但没有奖励？
- 建议: harvest 时间 < convert 时间 < 锁币结束时间？

*缺点*
- 锁定期结束后要多发一个交易换奖励

## 合约测试
BSC testnet
- Multi: 0x74e8e6eb31ef6970d2623a1c700cbe6f56f20f43
- ve: 0xa88e49CfFd199f77cDbF0B5149E2660A34b8c3D1

### Create lock
tokenId 1
lock amount 400000
lock time 1645771379
lock end 1648080000

| 时间 | vote power | |
| - | - | - |
| 1642000000 | 1927955352612881600000 |
| 1643000000 | 1610857432775236600000 |
| 1644000000 | 1293759512937591600000 |
| 1645770000 | 732496194824959950000 |
| 1645771244 | 732101725012681919620 | start |
| 1646000000 | 659563673262301600000 |
| 1646500000 | 501014713343479100000 |
| 1647000000 | 342465753424656600000 |
| 1647500000 | 183916793505834100000 |
| 1648000000 | 25367833587011600000 |
| 1648079999 | 317097919837645 |
| 1648080000 | 0 | end |
| 1649000000 | 0 |

##3 Increace lock amount
tokenId 1
lock amount increace 1000
lock amount 41000
lock time 1645771379
lock end 1648080000
锁定一个月

| 时间 | vote power | |
| - | - | - |
| 1642000000 | 1976154236428208960000 |
| 1643000000 | 1651128868594621960000 |
| 1644000000 | 1326103500761034960000 |
| 1645770000 | 750808599695585970000 |
| 1645771244 | 750404268138000987772 | start |
| 1646000000 | 676052765093860960000 |
| 1646500000 | 513540081177067460000 |
| 1647000000 | 351027397260273960000 |
| 1647500000 | 188514713343480460000 |
| 1648000000 | 26002029426686960000 |
| 1648079999 | 325025367833587 |
| 1648080000 | 0 | end |
| 1649000000 | 0 |

### increase unlock time
tokenId 1
increase time 5184000 （2个月）
lock end 1650499200
```
lock end = old lock start * WEEK / WEEK + 5184000
```
延长了 4 个星期

| 时间 | vote power | |
| - | - | - |
| 1642000000 | 2762455606291222630400 |
| 1643000000 | 2437430238457635630400 |
| 1644000000 | 2112404870624048630400 |
| 1645770000 | 1537109969558599640400 |
| 1645771244 | 1536705638001014658172 | start |
| 1646000000 | 1462354134956874630400 |
| 1646500000 | 1299841451040081130400 |
| 1647000000 | 1137328767123287630400 |
| 1647500000 | 974816083206494130400 |
| 1648000000 | 812303399289700630400 |
| 1648079999 | 786301694888381503987 |
| 1648080000 | 786301369863013670400 | old end |
| 1649000000 | 487278031456113630400 |
| 1650000000 | 162252663622526630400 |
| 1650499199 | 325025367833587 |
| 1650499200 | 0 | new end |
| 1651000000 | 0 |
