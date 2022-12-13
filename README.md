# otc-service

⭐ Developed / Developing by Generation Foundation

### **User actions**

1. (OTC Constructor) Create
2. Approve
3. Deposit (Complete → Distribution when the last user deposits)
4. Cancel (Refund)

### OTC process

Let the user press the minimum number of buttons by combining the actions the user actually takes.

1. Create OTC
2. Deposit (Approve + Deposit)

### **What to Exchange**

1. Coin, Token (ERC20 Token, Native Coin (ETH, GEN, MATIC, etc...))
2. NFTs
3. File Path (IPFS URL): Document, photo, video, text, etc.

### Condition

1. Only one OTC speech bubble can be left open between users A and B.
2. When OTC is open between users A and B, A and C can open a speech bubble.

### Token Exchange Description

1. It has to work on top of the Ethereum network. (How to present the Ethereum network in a nice UI in a wallet?)
2. Generate UID by combining 0xAAA + 0xBBB in escrow array
3. If the UID is in use, cancellation is required. (no time limit)
     1. If one of the two cancels, both tokens are refunded to the original user.
4. When the creator creates OTC, the token set by the creator can be deposited.
5. When you press the Deposit button, it is divided into two steps and executed... All of the approve and deposit below must be executed with one action.
     1. The first step is the approve step
     2. The second step is running deposit
6. When both tokens and quantity specified by the creator are deposited, both tokens are transferred to the other party. When the last deposit quantity and tokens are confirmed, they are automatically distributed.
7. Receive 0.3% commission from both parties. (Pile up in Escrow contract and enable Withdraw)
8. Record the history.

### File Exchange Description

1. The app uploads the file to IPFS, registers the received ipfs url to the 3 seconds club server, and receives the fileId.
2. Register the file ID in the OTC file transaction contract. At this time, the contract verifies the file ID and registration account in the DB by oraclize (renamed provable). For example, if the other party raised 100 USDT, which corresponds to the file price, it will be automatically distributed after verification.
3. The file purchaser acquires the ipfs url through API verification on the 3 seconds club server.