// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";

contract VRF is
    VRFV2WrapperConsumerBase,
    ConfirmedOwner
{
    struct RequestStatus {
        uint256 paid; // amount paid in link
        bool fulfilled; // whether the request has been successfully fulfilled
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        internal s_requests; /* requestId --> requestStatus */

    // past requests Id.
    uint256[] internal requestIds;
    uint256 internal lastRequestId;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
    uint32 numWords = 1;

    // Address LINK - hardcoded for Sepolia
    address linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // address WRAPPER - hardcoded for Sepolia
    address wrapperAddress = 0xab18414CD93297B0d12ac29E63Ca20f515b3DB46;

    constructor()
        ConfirmedOwner(msg.sender)
        VRFV2WrapperConsumerBase(linkAddress, wrapperAddress)
    {}

    function requestRandomWords()
        internal
        onlyOwner
        returns (uint256 requestId)
    {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        return requestId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(linkAddress);
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }
}

contract LotteryFive is VRF {
    struct Member {
        address addr;
        uint amount;
    }

    struct RoundState {
        Member[] members;
        uint numMembers; 
    }

    uint[] public roundsCompleted;
    uint public currentRound;
    
    // for every round, we have a request that we get from VRF Random words function when we call performDraw
    mapping(uint => uint256) internal draws;     // round to request Id
    mapping(uint => RoundState) internal roundStates; // round to round state, every round has a state. In this case a round has Members array which keeps every member info and number of mmembers

    uint private constant MIN_AMT = 1000000000000000;   // In Wei

    constructor() VRF() {
        currentRound = 1;
        RoundState storage roundState = roundStates[currentRound];
        for(uint i = 0; i < 5; i++) {
            Member memory member = Member(address(0), 0);
            roundState.members.push(member);
        }
    }

    function performDraw() external onlyOwner returns (uint256) {
        RoundState storage roundState = roundStates[currentRound];
        require(roundState.numMembers == 5, "Number of members must be 5 before draw can be performed");
        uint256 requestId = requestRandomWords();
        draws[currentRound] = requestId;
        roundsCompleted.push(currentRound);
        currentRound += 1;
        roundState = roundStates[currentRound];
        for(uint i = 0; i < 5; i++) {
            Member memory member = Member(address(0), 0);
            roundState.members.push(member);
        }
        return requestId; 
    }

    function checkWinner(uint _round) public view returns (address) {
        require(_round > 0, 'round must be greater than 0');
        require(_round < currentRound, 'round must be less than the current round');
        uint256 requestId = draws[_round];
        RequestStatus storage requestStatus = s_requests[requestId];
        if (requestStatus.fulfilled) {
            uint256 randomValue = requestStatus.randomWords[0];
            uint winnerId = randomValue % 5;
            RoundState storage roundState = roundStates[_round];
            return roundState.members[winnerId].addr;
        }
        return address(0);
    }

    function join() external payable {
        // check if the number of members are less than 5
        RoundState storage roundState = roundStates[currentRound];
        require(roundState.numMembers < 5, "Number of members are already 5. Please try to join in next round");
        for(uint i = 0; i < 5; i++) {
            require(msg.sender != roundState.members[i].addr, "You have already registered for this round");
        }
        require(msg.value >= MIN_AMT, "You must invest at least 0.001 ETH in the lottery round");
        for(uint i = 0; i < 5; i++) {
            if (roundState.members[i].addr == address(0)) {
                roundState.members[i].addr = msg.sender;
                roundState.members[i].amount = msg.value;
                roundState.numMembers += 1;
                return;
            }
        }
    }

    function withdraw() external {
        RoundState storage roundState = roundStates[currentRound];
        for(uint i = 0; i < 5; i++) {
            if (roundState.members[i].addr == msg.sender) {
                // keep 20% as penalty
                uint amt = (roundState.members[i].amount * 4)/5;
                address payable _to = payable(msg.sender);
                roundState.members[i].addr = address(0);
                roundState.members[i].amount = 0;
                roundState.numMembers -= 1;
                _to.transfer(amt);
                return;
            }
        }
    }

    function redeemPrize(uint _round) external {
        address winner = checkWinner(_round);
        require(winner != address(0), "Winner is not yet decided for the draw");
        require(winner == msg.sender, "You are not the winner");
        RoundState storage roundState = roundStates[_round];
        uint totalAmount = 0;
        for(uint i = 0; i < 5; i++) {
            totalAmount += roundState.members[i].amount;
        }
        // transfer 90% of the amount to the winner, keep 10% as commision
        address payable _to = payable(msg.sender);
        uint winningAmount = (totalAmount*9)/10;
        _to.transfer(winningAmount);
    }

    function contractBalance() external onlyOwner view returns (uint) {
        return address(this).balance;
    }

}