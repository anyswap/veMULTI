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
    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint);
    function ownerOf(uint) external view returns (address);
    function create_lock(uint _value, uint _lock_duration) external returns (uint)
}

contract Reward {
    using SafeERC20 for IERC20;

    /// @notice 一次奖励活动设置.
    /// claimPowerDeadline < referenceTime
    /// referenceTime < bonusTime (optional)
    /// @param claimPowerDeadline claim power 最终时间.
    /// @param referenceTime 检查 power 的参考时间.
    /// @param bonusTime 开始发奖励的时间.
    struct EpochInfo {
        uint128 claimPowerDeadline;
        uint128 referenceTime;
        uint128 bonusTime;
    }

    /// @notice 奖励内容.
    /// @param rewardTOken 奖励代币合约地址.
    /// @param totalAmount 奖励代币总数.
    struct RewardInfo {
        address rewardToken;
        uint256 totalAmount;
    }

    /// @dev Ve nft.
    address public _ve;

    /// @dev 分红记录.
    EpochInfo[] public epochInfo;
    /// @dev 已领取过的 epoch.
    mapping(uint => RewardInfo) public rewardInfo; // epoch -> reward info
    /// @dev 每个 epoch 记录的 user power.
    mapping(uint => mapping(uint => uint)) public userPower; // epochId -> power
    /// @dev 每个 epoch 记录的总 power.
    mapping(uint => uint) public totalPower; // epochId -> power

    address public admin;

    event LogAddEpoch(uint indexed pid, EpochInfo epochInfo);
    event LogSetRewardToken(uint indexed pid, address token, uint amount);
    event LogAddRewardToken(uint indexed pid, uint amount);
    event LogClaimPower(uint indexed pid, uint tokenId, uint power);
    event LogClaimReward(uint indexed pid, uint tokenId, uint amount);

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    constructor (
        address _ve_,
        address multi_
    ) {
        admin = msg.sender;
        _ve = _ve_;
    }

    function transferAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function latestEpoch() external view returns(uint) {
        return EpochInfo.length - 1;
    }

    /// @notice 增加一次奖励活动
    /// @param claimPowerDeadline_ 记录 power 的截止时间.
    /// @param referenceTime_ ve power 参考时间.
    /// @param bonusTime_ 奖励开放时间.
    function addEpoch(uint claimPowerDeadline_, uint referenceTime_, uint bonusTime_) external onlyAdmin {
        require(claimPowerDeadline_ < referenceTime_);
        require(claimPowerDeadline_ < bonusTime_);
        epochInfo.push(EpochInfi{
            claimPowerDeadline: claimPowerDeadline_,
            referenceTime: referenceTime_,
            bonusTime: bonusTime_
        });

        rewardInfo[epochInfo.length()-1] = RewardInfo(address(0), 0);
        emit LogAddEpoch(epochInfo.length()-1, epochInfo);
    }

    /// @notice 设置奖励内容
    /// @param epochId 奖励活动的编号.
    /// @param token 奖励代币地址.
    /// @param amount 奖励代币数量, 可以为 0.
    function setRewardToken(uint epochId, address token, uint amount) external onlyAdmin {
        EpochInfi memory epoch = epochInfo[epochId];
        require(block.timestamp < epoch.bonusTime);
        // admin 必须再 epoch.bonusTime 之前设定好奖励, 否则无法分配奖励.
        // 如果错过时间, 可以另行部署补救合约, 根据记录的 power 分配奖励.
        rewardInfo[epochId].rewardToken = token;
        if (amount > 0) {
            IERC20(token.safeTransferFrom(msg.sender, address(this), amount);
        }
        emit LogSetRewardToken(epochId, token, amount);
    }

    /// @notice 增加奖励数量, 允许任何人添加, 奖励的币种必须由 admin 设定
    /// @param epochId 奖励活动的编号.
    /// @param amount 奖励的数量.
    function addRewardToken(uint epochId, uint amount) external {
        EpochInfi memory epoch = epochInfo[epochId];
        require(block.timestamp < epoch.bonusTime);
        // admin 必须再 epoch.bonusTime 之前存入全部奖励, 否则会造成混乱.
        // 如果错过时间, 可以另行部署补救合约, 根据记录的 power 分配奖励.
        require(rewardInfo[epochId].rewardToken != address(0));
        IERC20(rewardInfo[epochId].rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        emit LogAddRewardToken(epochId, amount);
    }

    /// @notice 提交 NFT power 记录
    /// @param epochId 奖励活动的编号.
    /// @param tokenId ve id.
    function claimPower(uint epochId, uint tokenId) external returns(uint amount) {
        EpochInfi memory epoch = epochInfo[epochId];
        require(block.timestamp < epoch.claimPowerDeadline);
        uint power = ve(_ve).balanceOfNFTAt(epoch.referenceTime);
        if (power > userPower[epochId][tokenId]) {
            uint dp = power - userPower[epochId][tokenId];
            userPower[epochId][tokenId] += dp;
            totalPower[epochId] += dp;
        }
        emit LogClaimPower(epochId, tokenId, power);
    }

    /// @notice 计算可以领取的数量
    /// @param epochId 奖励活动的编号.
    /// @param tokenId ve id.
    function getReward(uint epochId, uint tokenId) view external returns(uint amount) {
        EpochInfi memory epoch = epochInfo[epochId];
        RewardInfo memory _rewardInfo = rewardInfo[epochId];
        uint power = userPower[epochId][tokenId];
        /// @todo 检查计算
        if (_rewardInfo.totalAmount > 0) {
            amount = _rewardInfo.totalAmount * power / totalPower[epochId];
        }
        return;
    }

    /// @notice 领取奖励
    /// @param epochId 奖励活动的编号.
    /// @param tokenId ve id.
    function claimReward(uint epochId, uint tokenId) external {
        EpochInfi memory epoch = epochInfo[epochId];
        require(block.timestamp >= epoch.bonusTime);
        RewardInfo memory _rewardInfo = rewardInfo[epochId];
        require(_rewardInfo.rewardToken != address(0));
        uint power = userPower[epochId][tokenId];
        uint amount;
        /// @todo 检查计算
        if (_rewardInfo.totalAmount > 0) {
            amount = _rewardInfo.totalAmount * power / totalPower[epochId];
        }
        if (amount > 0) {
            IERC20(_rewardInfo.rewardToken).safeTransfer(ve(_ve).ownerOf(tokenId));
            emit LogClaimReward(epochId, tokenId, amount);
        }
    }

    /// @notice 锁入 Multi 生成 ve, 同时 claim power
    /// @param epochId 奖励活动编号.
    /// @param _value Amount to deposit.
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week).
    function depositMultiAndClaimPower(uint epochId, uint _value, uint _lock_duration) external returns(uint veId) {
         veId = ve(_ve).create_lock(_value, _lock_duration);
         claimPower(epochId, veId);
         return;
    }
}