// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

library Address {
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != 0x0 && codehash != accountHash);
    }
}

library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function callOptionalReturn(IERC20 token, bytes memory data) private {
        require(address(token).isContract(), "SafeERC20: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

interface ve {
    function balanceOfAtNFT(uint _tokenId, uint _block) external view returns (uint);
    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint);
    function totalSupplyAt(uint _block) external view returns (uint);
    function totalSupplyAtT(uint t) external view returns (uint);
    function ownerOf(uint) external view returns (address);
    function create_lock(uint _value, uint _lock_duration) external returns (uint);
}

contract Reward {
    using SafeERC20 for IERC20;

    struct EpochInfo {
        uint initTime;
        uint initBlock;
        uint startBlock; // 1号
        uint endBlock; // 30号
        uint rewardPerBlock; // totalReward * multiplier / (endBlock - startBlock)
        uint totalReward;
        uint snapshotBlock; // 随便几号, 小于1号, 1号~30号, 大于30号都可以
    }

    /**
    |---- start -------------- snapshot -------------- end ---->|
    |------------ ^ interval 1--------------------------------->|
    |----------------------------------- ^ interval 2 --------->|
    - 总奖励在 start -> end 这段时间内均匀释放.

    - interval 1 可以追加 power 提高收益,
    别人追加 power 会降低自己的比重, 越早越频繁 claim 收益越好;

    - interval 2 追加 power 不会提高收益,
    收益和 claim 先后无关.

    - 补充奖励？
     */

    /// @dev Ve nft
    address public immutable _ve;
    /// @dev reward erc20 token, USDT
    address public immutable rewardToken;
    /// @dev multiplier
    uint immutable multiplier = 1000000;

    /// @dev 奖励记录.
    EpochInfo[] public epochInfo;
    /// @dev unexpired 未过期
    uint[] public unexpired;
    /**
    unexpired                   0   1   2
                                100 101 102
                                |   |   |
    epochInfo   0   1   2   ... 100 101 102
     */

    /// @dev 用户上一次领取的区块高度.
    mapping(uint => mapping(uint => uint)) public userLastClaimBlock; // tokenId -> epoch id -> last claim block
    /// @dev 已经领取的奖励
    mapping(uint => uint) public totalClaimed; // epochInfo index -> total claimed amount

    uint public immutable duration = 360 days; // 过期后剩余奖励归开发者，防止数组过长
    uint public immutable averageBlockTime; // 出块时间, 单位是秒

    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    event LogClaimReward(uint tokenId, uint epochId, uint reward);
    event LogAddEpoch(uint epochId, EpochInfo epochInfo);

    constructor (
        address _ve_,
        address rewardToken_,
        uint averageBlockTime_
    ) {
        admin = msg.sender;
        _ve = _ve_;
        rewardToken = rewardToken_;
        averageBlockTime = averageBlockTime_;
    }

    function getPower(uint tokenId, uint epochId) view public returns (uint) {
        EpochInfo memory epoch = epochInfo[epochId];
        if (block.number < epoch.snapshotBlock) {
            return ve(_ve).balanceOfNFTAt(tokenId, averageBlockTime * (epoch.snapshotBlock - epoch.initBlock) + epoch.initTime);
        } else {
            return ve(_ve).balanceOfAtNFT(tokenId, epoch.snapshotBlock);
        }
    }

    function getTotalPower(uint epochId) view public returns (uint) {
        EpochInfo memory epoch = epochInfo[epochId];
        if (block.number < epoch.snapshotBlock) {
            return ve(_ve).totalSupplyAtT(averageBlockTime * (epoch.snapshotBlock - epoch.initBlock) + epoch.initTime);
        } else {
            return ve(_ve).totalSupplyAt(epoch.snapshotBlock);
        }
    }

    function transferAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function addEpoch(uint startBlock, uint endBlock, uint totalReward, uint snapshotBlock) external onlyAdmin returns(uint) {
        assert(block.number < endBlock && startBlock < endBlock);
        uint rewardPerBlock = totalReward * multiplier / (endBlock - startBlock);
        uint epochId = epochInfo.length;
        epochInfo.push(EpochInfo(block.timestamp, block.number, startBlock, endBlock, rewardPerBlock, totalReward, snapshotBlock));
        unexpired.push(epochId);
        checkExpired();
        emit LogAddEpoch(epochId, epochInfo[epochId]);
        return epochId;
    }

    /// @notice query pending reward by epoch
    function pendingReward(uint tokenId, uint epochId) public view returns (uint) {
        // 过期的未过期的都可以
        EpochInfo memory epoch = epochInfo[epochId];
        uint power = getPower(tokenId, epochId);
        uint totalPower = getTotalPower(epochId);
        uint last = userLastClaimBlock[tokenId][epochId];
        uint reward = epoch.rewardPerBlock * (block.number - last) * power / totalPower / multiplier;
        return reward;
    }

    /// @notice query all unexpired pending reward
    function pendingReward(uint tokenId) external view returns (uint reward) {
        // 只显示未过期的
        for (uint i = 0; i < unexpired.length; i++) {
            reward += pendingReward(tokenId, unexpired[i]);
        }
        return reward;
    }

    function claimReward(uint tokenId, uint epochId) public {
        uint reward = pendingReward(tokenId, epochId);
        userLastClaimBlock[tokenId][epochId] = block.number;
        IERC20(rewardToken).safeTransfer(ve(_ve).ownerOf(tokenId), reward);
        emit LogClaimReward(tokenId, epochId, reward);
    }

    function claimReward(uint tokenId) external {
        for (uint i = 0; i < unexpired.length; i++) {
            claimReward(tokenId, unexpired[i]);
        }
    }

    function checkExpired() public onlyAdmin {
        // 把 epochInfo 头部连续的过期 epoch 移除
        // 缩短 epochInfo 长度
        uint firstUnexpired = 0;
        EpochInfo memory epoch;
        for (uint i = 0; i < unexpired.length; i++) {
            epoch = epochInfo[i];
            if (epoch.initTime + duration < block.timestamp) {
                firstUnexpired++;
            } else {
                break;
            }
        }
        if (firstUnexpired < 1) {
            return;
        }
        for (uint i = firstUnexpired; i < unexpired.length; i++) {
            unexpired[i-firstUnexpired] = unexpired[i];
        }
        for (uint i = 0; i < firstUnexpired; i++) {
            unexpired.pop();
        }
    }
}
