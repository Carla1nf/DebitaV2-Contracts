pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

interface veSolid {
     struct LockedBalance {
        int128 amount;
        uint end;
    }

    function locked(uint id) external view returns(LockedBalance memory);
}

interface IDebitaOfferFactoryV2 {
    function debitaLoanFactoryV2() external returns (address);

    function isContractVeNFT(address _assetAddress) external returns (bool);

    function emitOfferCanceled(bool _isLending) external;
    function emitOfferFundsAgain(address owner, bool isOwnerLender) external;
    function emitOfferNoFunds(bool isOwnerLender) external;
    function emitAcceptedOffer(address lendingAddress, uint lendingAmount) external;
}

interface IDebitaFactoryV2 is IERC721Receiver {   


    function mintOwnerships(
        address[2] calldata owners
    ) external returns (uint[2] memory);

    function setMappingIdToLoan(address loanAddress, uint[2] calldata nftIds) external;

    function createLoanV2(
        uint[2] calldata nftIDS,
        address[2] calldata assetAddresses,
        uint256[2] calldata assetAmounts,
        bool[2] calldata isAssetNFT,
        uint32[3] calldata loanData, // [0] = interestRate, [1] = _paymentCount, [2] = _timelap
        uint256[3] calldata nftData,
        address interest_address,
        address offer_address
    ) external returns (address);
}

contract DebitaV2Offers is ReentrancyGuard {
    event LoanCreated(
        address indexed lendingAddress,
        address indexed loanAddress,
        uint lenderId,
        uint borrowerId
    );

    struct OfferInfo {
        address[2] assetAddresses;
        uint256[2] assetAmounts;
        bool[2] isAssetNFT;
        uint16 interestRate;
        uint[2] nftData; // [0]: the id of the NFT that the owner transfered here (could be borrower or lender) in case lending/borrowing is NFT else 0 , [1]: interest Amount
        int128 valueOfVeNFT;
        uint8 paymentCount;
        uint32 _timelap;
        bool isLending;
        bool isPerpetual;
        bool isActive;
        address interest_address; // in case lending is NFT else 0
    }

    OfferInfo private storage_OfferInfo;

    address public immutable owner;
    address public debitaFactoryLoansV2;
    address private immutable debitaFactoryOfferV2;
    uint private totalLending;
    uint private totalCollateral;
    int128 private totalVeNFT;
    uint lastEditedBlock;
    bool public canceled;

    mapping(address => bool) private isSenderALoan;

    modifier afterCooldown() {
        require(
            block.timestamp - lastEditedBlock > 5 minutes,
            "Cooldown time is not over yet."
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function.");
        _;
    }

    modifier onlyActive() {
        require(storage_OfferInfo.isActive, "Offer is not active.");
        _;
    }

    modifier onlyLoans() {
        require(
            isSenderALoan[msg.sender],
            "Only loans can call this function."
        );
        _;
    }

    constructor(
        address[2] memory assetAddresses,
        uint256[2] memory assetAmounts,
        bool[2] memory isAssetNFT,
        uint16 _interestRate,
        uint[2] memory _nftData, // In case of NFT, nftData[0] = nftID, nfData[1] = interest Amount
        int128 veValue,
        uint8 _paymentCount,
        uint32 _timelap,
        bool[2] memory loanBooleans, // isLending, isPerpetual
        address[2] memory loanExtraAddresses // [0]: owner, [1]: interest_address
    ) {
        storage_OfferInfo = OfferInfo({
            assetAddresses: assetAddresses,
            assetAmounts: assetAmounts,
            isAssetNFT: isAssetNFT,
            interestRate: _interestRate,
            nftData: _nftData,
            valueOfVeNFT: veValue,
            paymentCount: _paymentCount,
            _timelap: _timelap,
            isLending: loanBooleans[0],
            isPerpetual: loanBooleans[1],
            isActive: true,
            interest_address: loanExtraAddresses[1]
        });
        owner = loanExtraAddresses[0];
        debitaFactoryLoansV2 = IDebitaOfferFactoryV2(msg.sender).debitaLoanFactoryV2();
        debitaFactoryOfferV2 = msg.sender;
        totalLending = assetAmounts[0];
        totalCollateral = assetAmounts[1];
        totalVeNFT = veValue;
    }

    function cancelOffer() external onlyOwner onlyActive nonReentrant {

        OfferInfo memory m_offer = storage_OfferInfo;
        m_offer.isPerpetual = false;
        m_offer.isActive = false;
        canceled = true;
        storage_OfferInfo = m_offer;
        uint index = m_offer.isLending ? 0 : 1;

        transferAssets(
            address(this),
            owner,
            m_offer.assetAddresses[index],
            m_offer.assetAmounts[index],
            m_offer.isAssetNFT[index],
            m_offer.nftData[0]
        );

        IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitOfferCanceled(m_offer.isLending);
    }


    function acceptOfferAsBorrower(
        uint amount,
        uint sendingNFTID
    ) public nonReentrant onlyActive afterCooldown {
        OfferInfo memory m_offer = storage_OfferInfo;
        uint porcentage = (amount * 10000) / m_offer.assetAmounts[0];

        bool isCollateral_veNFT = IDebitaOfferFactoryV2(debitaFactoryOfferV2).isContractVeNFT(m_offer.assetAddresses[1]);
       
  
        if(isCollateral_veNFT && !m_offer.isAssetNFT[0]) {
            
            veSolid.LockedBalance memory lockedData = veSolid(m_offer.assetAddresses[1]).locked(sendingNFTID);
            int128 lockedAmount = lockedData.amount;
            int128 expectedValue = ((m_offer.valueOfVeNFT) * int128(int(porcentage))) / 10000;
            require((lockedAmount) >= (expectedValue), "Must be greater than veNFT value");
            m_offer.valueOfVeNFT -= expectedValue;

        } else if (m_offer.isAssetNFT[0] || m_offer.isAssetNFT[1]) {
            require(porcentage == 10000, "Must be 100%");
        }


        require(m_offer.isLending, "Owner is not lender");
        require(porcentage <= 10000 && porcentage >= 10, "100% - 0.1%");
        require(m_offer.isActive, "Offer is not active");

        uint256 collateralAmount = 1;
        // [0]: Lending  [1]: Collateral
        if(!isCollateral_veNFT) {
            collateralAmount = (m_offer.assetAmounts[1] * porcentage) /
            10000;
            m_offer.assetAmounts[1] -= collateralAmount;

        }
         m_offer.assetAmounts[0] -= amount;

         // Active = false if there is no more assets
         m_offer.isActive = !(m_offer.assetAmounts[0] == 0);
     
        
        // transfer collateral to this contract before creating the loan & nfts
        transferAssets(
            msg.sender,
            address(this),
            m_offer.assetAddresses[1],
            collateralAmount,
            m_offer.isAssetNFT[1],
            sendingNFTID
        );
        
        storage_OfferInfo = m_offer;

        uint[2] memory ids = IDebitaFactoryV2(debitaFactoryLoansV2).mintOwnerships(
            [owner, msg.sender]
        );
        address loanAddress = IDebitaFactoryV2(debitaFactoryLoansV2).createLoanV2(
            ids,
            m_offer.assetAddresses,
            [amount, collateralAmount],
            m_offer.isAssetNFT,
            [m_offer.interestRate, m_offer.paymentCount, m_offer._timelap],
            [m_offer.nftData[0], sendingNFTID, m_offer.nftData[1]],
            m_offer.interest_address,
            address(this)
        );
        IDebitaFactoryV2(debitaFactoryLoansV2).setMappingIdToLoan(loanAddress, ids);
        isSenderALoan[loanAddress] = true;
        
        // Send collateral to loanAddress
        transferAssets(
            address(this),
            address(loanAddress),
            m_offer.assetAddresses[1],
            collateralAmount,
            m_offer.isAssetNFT[1],
            sendingNFTID
        );

        // Transfer tokens to the borrower
        transferAssets(
            address(this),
            msg.sender,
            m_offer.assetAddresses[0],
            amount,
            m_offer.isAssetNFT[0],
            m_offer.nftData[0]
        );

         if(m_offer.assetAmounts[0] == 0) {
          IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitOfferNoFunds(m_offer.isLending);
         }

        IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitAcceptedOffer(m_offer.assetAddresses[0], amount);
    }

    function acceptOfferAsLender(
        uint amount,
        uint sendingNFTID
    ) public nonReentrant onlyActive afterCooldown {
        OfferInfo memory m_offer = storage_OfferInfo;
        uint porcentage = (amount * 10000) / m_offer.assetAmounts[0];

        if(IDebitaOfferFactoryV2(debitaFactoryOfferV2).isContractVeNFT(m_offer.assetAddresses[0])) {
            veSolid.LockedBalance memory lockedData = veSolid(m_offer.assetAddresses[0]).locked(sendingNFTID);
            int128 lockedAmount = lockedData.amount;

            require(lockedAmount >= (m_offer.valueOfVeNFT), "Must be greater than veNFT value");
        }
        require(!m_offer.isLending, "Owner is not borrower");
        require(porcentage <= 10000 && porcentage >= 10, "100% - 0.1%");
        require(m_offer.isActive, "Offer is not active");

        if (m_offer.isAssetNFT[0] || m_offer.isAssetNFT[1]) {
            require(porcentage == 10000, "Must be 100%");
        }

        uint256 collateralAmount = (m_offer.assetAmounts[1] * porcentage) /
            10000;

        m_offer.assetAmounts[0] -= amount;
        m_offer.assetAmounts[1] -= collateralAmount;

        if (m_offer.assetAmounts[0] == 0) {
            storage_OfferInfo.isActive = false;
        }

        // Sending Lending Assets to contract
        transferAssets(
            msg.sender,
            address(this),
            m_offer.assetAddresses[0],
            amount,
            m_offer.isAssetNFT[0],
            sendingNFTID
        );
        storage_OfferInfo = m_offer;

        uint[2] memory ids = IDebitaFactoryV2(debitaFactoryLoansV2).mintOwnerships(
            [msg.sender, owner]
        );

        address loanAddress = IDebitaFactoryV2(debitaFactoryLoansV2).createLoanV2(
            ids,
            m_offer.assetAddresses,
            [amount, collateralAmount],
            m_offer.isAssetNFT,
            [m_offer.interestRate, m_offer.paymentCount, m_offer._timelap],
            [sendingNFTID, m_offer.nftData[0], m_offer.nftData[1]],
            m_offer.interest_address,
            address(this)
        );
        IDebitaFactoryV2(debitaFactoryLoansV2).setMappingIdToLoan(loanAddress, ids);
        isSenderALoan[loanAddress] = true;

        // Send collateral to loanAddress
        transferAssets(
            address(this),
            address(loanAddress),
            m_offer.assetAddresses[1],
            collateralAmount,
            m_offer.isAssetNFT[1],
            m_offer.nftData[0]
        );

        // Transfer tokens to the borrower
        transferAssets(
            address(this),
            owner,
            m_offer.assetAddresses[0],
            amount,
            m_offer.isAssetNFT[0],
            sendingNFTID
        );

       if(m_offer.assetAmounts[0] == 0) {
          IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitOfferNoFunds(m_offer.isLending);
         }
    
     IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitAcceptedOffer(m_offer.assetAddresses[0], amount);

    }

    function insertAssets(uint assetAmount) public onlyLoans nonReentrant {
        OfferInfo memory m_offer = storage_OfferInfo;
        address assetAddress = m_offer.isLending
            ? m_offer.assetAddresses[0]
            : m_offer.assetAddresses[1];

         bool isCollateral_veNFT = IDebitaOfferFactoryV2(debitaFactoryOfferV2).isContractVeNFT(m_offer.assetAddresses[1]) && m_offer.isLending;
       
        transferAssets(
            msg.sender,
            address(this),
            assetAddress,
            assetAmount,
            m_offer.isAssetNFT[m_offer.isLending ? 0 : 1],
            m_offer.nftData[0]
        );

        m_offer.assetAmounts[m_offer.isLending ? 0 : 1] += assetAmount;

        uint amountOfAssetAdded = m_offer.isLending
            ? totalLending
            : totalCollateral;
        uint porcentageToAdd = (assetAmount * 10000000) / amountOfAssetAdded;

        if(isCollateral_veNFT) {
            m_offer.valueOfVeNFT += totalVeNFT * int128(int(porcentageToAdd)) / 10000000;
        } else {
              // Add the opposite asset
        uint oppositeOfAmountAsset = m_offer.isLending
            ? totalCollateral
            : totalLending;
        m_offer.assetAmounts[m_offer.isLending ? 1 : 0] +=
            (oppositeOfAmountAsset * porcentageToAdd) /
            10000000;

        }
        
        m_offer.isActive = true;
        storage_OfferInfo = m_offer;
        IDebitaOfferFactoryV2(debitaFactoryOfferV2).emitOfferFundsAgain(owner, m_offer.isLending);

       
    }


    function interactPerpetual(bool newType) public onlyOwner() nonReentrant {
        require(!canceled, "Offer is canceled");
        storage_OfferInfo.isPerpetual = newType;
    } 



// _newLoanData: [0] = interestRate, [1] = _paymentCount, [2] = _timelap
// _newAssetAmounts: [0] = lendingAmount, [1] = collateralAmount
    function editOffer(
        uint[2] calldata _newAssetAmounts,
        uint[3] calldata _newLoanData,
        int128 veValue,
        uint _newInterestRateForNFT
    ) public  onlyOwner() {
        require(!canceled, "Offer is canceled");
        OfferInfo memory m_offer = storage_OfferInfo;
        uint index = m_offer.isLending ? 0 : 1;
        lastEditedBlock = block.timestamp;
        if(
            _newLoanData[2] < 1 days || 
            _newLoanData[2] > 365 days ||
            _newAssetAmounts[0] == 0 ||
            _newAssetAmounts[1] == 0 ||
            _newLoanData[1] > 10 ||
            _newLoanData[1] == 0 ||
            _newLoanData[1] > _newAssetAmounts[0] ||
            _newLoanData[0] > 10000 || 
            m_offer.isAssetNFT[0] && _newLoanData[1] > 1 ||
            m_offer.isAssetNFT[0] && _newAssetAmounts[0] > 1 ||
            m_offer.isAssetNFT[1] && _newAssetAmounts[1] > 1 
        ) {
            revert();
        }
      
        address depositedAddress =  m_offer.assetAddresses[index];
        uint256 depositedAmount = m_offer.assetAmounts[index];
        

        transferAssets(address(this), msg.sender, depositedAddress, depositedAmount, false, 0);
        transferAssets(msg.sender, address(this), depositedAddress, _newAssetAmounts[index], false, 0);

        m_offer.assetAmounts[0] = _newAssetAmounts[0];
        m_offer.assetAmounts[1] = _newAssetAmounts[1];
        m_offer.interestRate = uint16(_newLoanData[0]);
        m_offer.paymentCount = uint8(_newLoanData[1]);
        m_offer._timelap = uint32(_newLoanData[2]);
        m_offer.valueOfVeNFT = veValue;
        m_offer.nftData[1] = _newInterestRateForNFT;
         
        storage_OfferInfo = m_offer;
        totalCollateral = _newAssetAmounts[1];
        totalLending = _newAssetAmounts[0];

      
    }

        function int128ToUint256(int128 signedValue) internal pure returns (uint256) {
        require(signedValue >= 0, "Input value must be non-negative");

        // You can directly cast an int to uint if it's non-negative
       // Convert int128 to int256
        int256 signedValue256 = int256(signedValue);

        // Convert int256 to uint256
        uint256 unsignedValue = uint256(signedValue256);
        return unsignedValue;
    }


    function getOffersData() public view returns (OfferInfo memory) {
        return storage_OfferInfo;
    }

    function transferAssets(
        address from,
        address to,
        address assetAddress,
        uint256 assetAmount,
        bool isNFT,
        uint nftID // 0 IF NOT NFT
    ) internal {
        if (isNFT) {
            ERC721(assetAddress).transferFrom(from, to, nftID);
        } else {
            if (from == address(this)) {
                require(ERC20(assetAddress).transfer(to, assetAmount), "Amount not sent");
            } else {
                require(ERC20(assetAddress).transferFrom(from, to, assetAmount), "Amount not sent");
            }
        }
    }
}
