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
    function totalSupplyAt(uint _block) external view returns (uint);
    function ownerOf(uint) external view returns (address);
}

contract Bonus {
    using SafeERC20 for IERC20;

    struct Bonus {
        uint256 amount;
        uint ts; // timestamp
        uint blk; // block
    }

    /// @dev 分红 token，usdc
    address public bonusToken;
    /// @dev Ve nft
    address public _ve;
    /// @dev 分红记录
    mapping(uint => Bonus) public bonusHistory; // epoch -> Bonus, epoch 要保证连续
    /// @dev 已领取过的 epoch
    mapping(uint => uint) public usersEpoch; // user -> epoch

    /// @dev 最新 epoch
    uint public latestEpoch;

    address public admin;

    event LogClaim(uint epoch, uint amount);
    event LogCreateBonus(uint epoch, Bonus bonus);

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    constructor (
        address _ve_,
        address bonusToken_
    ) {
        admin = msg.sender;
        _ve = _ve_;
        bonusToken = bonusToken_;
    }

    function transferAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    /// @dev 增加一次分红
    function createBonus(uint amount) external onlyAdmin {
        // 需要先授权
        IERC20(bonusToken).safeTransferFrom(msg.sender, address(this), amount);
        latestEpoch += 1;
        Bonus memory bonus = Bonus(amount, block.timestamp, block.number);
        bonusHistory[latestEpoch] = bonus;
        emit LogCreateBonus(latestEpoch, bonus);
    }

    /// @dev 计算可以领取的数量
    function canClaim(uint tokenId) view external returns(uint amount) {
        uint start = usersEpoch[tokenId] + 1;
        if (usersEpoch[tokenId] < latestEpoch) {
            return 0;
        }
        for (uint i = start; i <= latestEpoch; ++i) {
            uint totalAmount = bonusHistory[epoch].amount;
            uint blk = bonusHistory[epoch].block;
            // vote power 总量
            uint weight = ve(_ve).balanceOfNFTAt(tokenId, blk);
            // tokenId vote power
            uint totalWeight = ve(_ve).totalSupplyAt(blk);
            amount += totalAmount * weight / totalWeight;
        }
        return;
    }

    /// @dev 领取分红
    function claim(uint tokenId) external returns(uint amount) {
        require(msg.sender == ve(_ve).ownerOf(tokenId));
        require(usersEpoch[tokenId] < latestEpoch);
        // 更新 userEpoch
        usersEpoch[tokenId] = latestEpoch;
        // 计算 amount
        amount = canClaim(tokenId);
        require(amount > 0);

        IERC20(bonusToken).safeTransfer(msg.sender, amount);
        emit LogClaim(latestEpoch, amount);
        return;
    }
}