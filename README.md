# Multi 锁定挖矿
## VE (ve.sol)

Vote escrow (名字待定)，是一种 NFT，借鉴了 solidly ve

主要功能是锁定 Multi(ERC20), 获得 ve(NFT), 计算 ve 的 vote power

对 Multi 来说，vote power 可以称为 stake，作为分手续费的依据

`create_lock` 和 `create_lock_for` 锁定 Multi 创建 ve

`balanceOfNFT` 计算 ve 的 vote power，是按时间线性降低到 0 的

`balanceOfNFTAt` 计算某个块高上的 vote power

`point_history` 和 `user_point_history` 记录了全局和每个 ve 的历史记录，对齐到 week，可以计算每个历史块高上的 `balanceOfNFT`

point 记录了偏移量 bias 和斜率 slope，还有块高和时间戳

偏移量表示记录点上的 vote power 的值

斜率是每秒下降的 vote power

计算历史 vote power 时，先找到最近的 point，用 point 中记录的 bias 和 slope 来计算精确的 vote power

```
balanceOfNFT = lastpoint.bias - slope * （block time - lastpoint.time）
```

`increase_amount` 增加数量

`increase_unlock_time` 延长锁定时间

`withdraw` 在锁定期结束后提出 Multi

`merge` 合并同一个 owner 的两个 ve

`deposit`, `increase_amount`, `increase_unlock_time`, `merge`，`withdraw` 都会执行 `_checkpoint`，更新自己和全局的记录

任何人都可以通过 `checkpoint` 更新全局记录

`checkpoint` 记录全局的 point 以及某个 tokenId 的 point，会提前设置未来 255 周（5 年）的 `point`，如果 5 年内没有任何人 `deposit`, `withdraw`, 或手动触发 `checkpoint`，五年后 `balanceOfNFT` 的计算就崩坏了，但 `withdraw` 还是可以用的

`totalSupply` 计算当前区块的总 vote power，**不是 NFT 的总个数，不是典型的 ERC721**

`totalSupplyAt` 计算历史上某个块高的总 vote power

`totalSupplyAtT` 计算历史上某个时刻的总 vote power，时刻可以不是块高度，也可以是未来5年内预期的总 vote power

voter 这块功能应该删掉

    `voter` 是指 voter 合约，voter 合约有权设置 `voted`，`voted` 表示 tokenId 是否正在投票，正在投票的 NFT 不能转账

    
### 问题
- 改斜率？

## 分手续费 bonus.sol
admin 可以创建分红事件，转入 usdc

token owner 可以 claim 分红奖励，根据 `balanceOfNFTAt` 和 `totalSupplyAt` 计算 token owner 占的比例, 领取 usdc

## 合约地址
BSC testnet
- Multi: 0x74e8e6eb31ef6970d2623a1c700cbe6f56f20f43
- ve: 0xa88e49CfFd199f77cDbF0B5149E2660A34b8c3D1
