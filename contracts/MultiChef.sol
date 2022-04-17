// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;
pragma experimental ABIEncoderV2;

import "@OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Mintable is ERC20 {
    address public minter;

    constructor (string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        minter = msg.sender;
    }

    function decimals() public view virtual override returns (uint8) {
        return 1;
    }

    function mint(address to, uint256 amount) public {
        require(msg.sender == minter);
        _mint(to, amount);
    }
}

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint value) internal {
        callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function safeApprove(IERC20 token, address spender, uint value) internal {
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
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

// Source: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol + Claimable.sol
// Simplified by BoringCrypto

contract BoringOwnableData {
    address public owner;
    address public pendingOwner;
}

contract BoringOwnable is BoringOwnableData {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice `owner` defaults to msg.sender on construction.
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Transfers ownership to `newOwner`. Either directly or claimable by the new pending owner.
    /// Can only be invoked by the current `owner`.
    /// @param newOwner Address of the new owner.
    /// @param direct True if `newOwner` should be set immediately. False if `newOwner` needs to use `claimOwnership`.
    /// @param renounce Allows the `newOwner` to be `address(0)` if `direct` and `renounce` is True. Has no effect otherwise.
    function transferOwnership(
        address newOwner,
        bool direct,
        bool renounce
    ) public onlyOwner {
        if (direct) {
            // Checks
            require(newOwner != address(0) || renounce, "Ownable: zero address");

            // Effects
            emit OwnershipTransferred(owner, newOwner);
            owner = newOwner;
            pendingOwner = address(0);
        } else {
            // Effects
            pendingOwner = newOwner;
        }
    }

    /// @notice Needs to be called by `pendingOwner` to claim ownership.
    function claimOwnership() public {
        address _pendingOwner = pendingOwner;

        // Checks
        require(msg.sender == _pendingOwner, "Ownable: caller != pending owner");

        // Effects
        emit OwnershipTransferred(owner, _pendingOwner);
        owner = _pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Only allows the `owner` to execute the function.
    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        _;
    }
}

/// @notice 根据 sushiswap master chef 改写, 用于锁定 Multi 分手续费.
/// 没有 Masgter chef, 没有 alloc point.
/// 每个 pool 对应一个锁定期, 每个锁定期发行一种 ticket token, 每秒奖励固定的 ticket.
/// ticket holder 可以在 convertion time 之后兑换 reward token (USDT).
contract MultiChef is BoringOwnable {
    using SafeERC20 for IERC20;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `ticketDebt` The amount of ticket entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 ticketDebt;
    }

    /// @notice Info of each MCV2 pool.
    // /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of ticket to distribute per block.
    /// 每个锁币期对应一个 pool
    struct PoolInfo {
        uint128 accTicketPerShare;
        uint128 lastRewardTime;
        uint128 startTime;
        uint128 endTime;
    }

    struct RewardInfo {
        IERC20 ticketToken;
        IERC20 rewardToken;
        uint256 ticketConvertionTime;
        uint256 totalRewardAmount;
    }

    /// @notice Address of rewardInfo.
    mapping(uint256 => RewardInfo) public rewardInfo; // pid -> rewardInfo
    IMigratorChef public migrator;

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Multi token address;
    IERC20 public Multi;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    bytes public constant TICKET_TOKEN_CODE = type(ERC20Mintable).creationCode;

    uint256 private constant TICKET_PER_SECOND = 1e1; // 每秒 1 个
    uint256 private constant ACC_TICKET_PRECISION = 1e1; // 1 位小数

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, PoolInfo poolInfo, RewardInfo rewardInfo);
    event LogCreateTicketToken(uint256 pid, address ticket);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardTime, uint256 accTicketPerShare);
    event LogAddReward(uint256 indexed pid, uint256 amount);
    event LogConvertReward(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event LogInit();

    constructor() public {}

    function init() external {
        emit LogInit();
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice 创建 ticket token, minter 设为 MultiChef.
    /// @param pid The index of the pool. See `poolInfo`.
    function createTicketToken(uint256 pid) internal returns (address) {
        if (address(handler[target]) != address(0)) {
            return address(handler[target]);
        }
        string memory name = "MultiChef ticket token - " + pid;
        string memory symbol = "Ticket-" + pid;
        bytes memory code = abi.encodePacked(TICKET_TOKEN_CODE, abi.encode(name, symbol));
        address addr;
        assembly {
            addr := create2(0, add(code, 0x20), mload(code), pid) // pid as salt
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        emit LogCreateTicketToken(pid, addr);
        return addr;
    }

    /// @notice 新建一个奖励期. Can only be called by the owner.
    /// @param startTime 锁定奖励开始时间.
    /// @param endTime 锁定奖励结束时间.
    /// @param rewardToken 奖励代币.
    /// @param ticketConvertionTime 兑换 reward 开始时间
    function add(uint256 startTime, uint256 endTime, address rewardToken, uint256 ticketConvertionTime) external onlyOwner {
        require(startTime < endTime);
        require(block.timestamp.to128() < endTime);

        poolInfo.push(PoolInfo({
            lastRewardTime: startTime.to128(),
            accTicketPerShare: 0,
            startTime: startTime.to128(),
            endTime: endTime.to128()
        }));

        uint pid = poolInfo.length.sub(1);
        address _rewardTicket = createTicketToken();
        RewardInfo memory _rewardInfo = RewardInfo(IERC20(_rewardTicket), IERC20(rewardToken), ticketConvertionTime, 0);
        rewardInfo[poolInfo.length.sub(1)] = _rewardInfo;
        emit LogPoolAddition(pid, poolInfo[pid], rewardInfo[pid]);
    }

    /// @notice View function to see pending ticket on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending rewardTicket reward for a given user.
    function pendingTicket(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTicketPerShare = pool.accTicketPerShare;
        if (block.timestamp > pool.lastRewardTime) {
            uint256 time;
            if (block.timestamp < pool.endTime) {
                time = block.timestamp.sub(pool.lastRewardTime);
            } else {
                time = pool.endTime.sub(pool.lastRewardTime);
            }
            uint256 ticketReward = time.mul(TICKET_PER_SECOND);
            accTicketPerShare = accTicketPerShare.add(ticketReward);
        }
        pending = int256(user.amount.mul(accTicketPerShare) / ACC_TICKET_PRECISION).sub(user.ticketDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) external returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.number > pool.lastRewardTime) {
            uint256 time;
            if (block.timestamp < pool.endTime) {
                time = block.timestamp.sub(pool.lastRewardTime);
            } else {
                time = pool.endTime.sub(pool.lastRewardTime);
            }
            uint256 ticketReward = time.mul(TICKET_PER_SECOND);
            pool.accTicketPerShare = pool.accTicketPerShare.add((ticketReward).to128());

            pool.lastRewardTime = block.timestamp.to128();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardTime.to64(), pool.accTicketPerShare);
        }
    }

    /// @notice Deposit Multi tokens to MCV2 for ticket allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount Multi token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) external {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.ticketDebt = user.ticketDebt.add(int256(amount.mul(pool.accTicketPerShare) / ACC_TICKET_PRECISION));

        Multi.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw Multi tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount Multi token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) external {
        PoolInfo memory pool = updatePool(pid);
        /// @notice 锁币结束时间之前禁止提出, 除非 emergency withdraw 放弃奖励
        require(block.timestamp >= pool.endTime);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.ticketDebt = user.ticketDebt.sub(int256(amount.mul(pool.accTicketPerShare) / ACC_TICKET_PRECISION));
        user.amount = user.amount.sub(amount);
        
        Multi.safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of ticket rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedTicket = int256(user.amount.mul(pool.accTicketPerShare) / ACC_TICKET_PRECISION);
        uint256 _pendingTicket = accumulatedTicket.sub(user.ticketDebt).toUInt256();

        // Effects
        user.ticketDebt = accumulatedTicket;

        // Interactions
        if (_pendingTicket != 0) {
            ERC20Mintable(rewardInfo[pid].ticketToken).mint(to, _pendingTicket);
        }

        emit Harvest(msg.sender, pid, _pendingTicket);
    }
    
    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and ticket rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) external {
        PoolInfo memory pool = updatePool(pid);
        /// @notice 锁币结束时间之前禁止提出, 除非 emergency withdraw 放弃奖励
        require(block.timestamp >= pool.endTime);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedTicket = int256(user.amount.mul(pool.accTicketPerShare) / ACC_TICKET_PRECISION);
        uint256 _pendingTicket = accumulatedTicket.sub(user.ticketDebt).toUInt256();

        // Effects
        user.ticketDebt = accumulatedTicket.sub(int256(amount.mul(pool.accTicketPerShare) / ACC_TICKET_PRECISION));
        user.amount = user.amount.sub(amount);
        
        // Interactions
        ERC20Mintable(rewardInfo[pid].ticketToken).mint(to, _pendingTicket);

        Multi.safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingTicket);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) external {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.ticketDebt = 0;

        // Note: transfer can fail or succeed if `amount` is zero.
        Multi.safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }

    /// @notice Add reward token for pid.
    /// Add reward before ticket convertion time.
    /// 设想由官方账户执行, 但也允许其他任何人执行
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount 奖励数量.
    function addReward(uint256 pid, uint256 amount) external {
        /// @notice ticket convert time 开始后禁止增加奖励，防止混乱
        /// 如果忘记添加奖励，可以另外设置一个合约，仍然按 ticket 份额分配奖励
        require(block.timestamp < _rewardInfo.ticketConvertionTime);
        rewardInfo[pid].rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardInfo[pid].totalRewardAmount = rewardInfo[pid].totalRewardAmount.add(amount);
        emit LogAddReward(pid, amount);
    }

    /// @notice Convert reward ticket to reward token.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount 转化的 ticket 数量.
    function convertReward(uint256 pid, uint256 amount, address to) external {
        RewardInfo _rewardInfo = rewardInfo[pid];
        require(block.timestamp >= _rewardInfo.ticketConvertionTime);
        _rewardInfo.ticketToken.safeTransferFrom(msg.sender, address(this), amount);
        /// @todo 检查计算
        uint256 reward = _rewardInfo.totalRewardAmount.mul(amount).div(_rewardInfo.ticketToken.totalSupply());
        if (reward > 0) {
            _rewardInfo.rewardToken.safeTransfer(to, reward);
        }
        emit LogConvertReward(msg.sender, pid, amount, to);
    }

    /// @notice Convert all reward ticket to reward token.
    /// @param pid The index of the pool. See `poolInfo`.
    function convertAllReward(uint256 pid, address to) external {
        RewardInfo _rewardInfo = rewardInfo[pid];
        require(block.timestamp >= _rewardInfo.ticketConvertionTime);
        uint256 amount = _rewardInfo.ticketToken.balanceOf(msg.sender);
        _rewardInfo.ticketToken.safeTransferFrom(msg.sender, address(this), amount);
        /// @todo 检查计算
        uint256 reward = _rewardInfo.totalRewardAmount.mul(amount).div(_rewardInfo.ticketToken.totalSupply());
        if (reward > 0) {
            _rewardInfo.rewardToken.safeTransfer(to, reward);
        }
        emit LogConvertReward(msg.sender, pid, amount, to);
    }

    /// @notice View function to see pending reward on frontend.
    /// @param pid The index of the pool. See `poolInfo`.
    function pendingReward(uint256 pid) external view returns (uint256) {
        RewardInfo _rewardInfo = rewardInfo[pid];
        uint256 amount = _rewardInfo.ticketToken.balanceOf(msg.sender);
        /// @todo 检查计算
        uint256 reward = _rewardInfo.totalRewardAmount.mul(amount).div(_rewardInfo.ticketToken.totalSupply());
        return reward;
    }
}