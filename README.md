# otc-service
⭐ Developed / Developing by Generation Foundation

![OTC Flow](https://user-images.githubusercontent.com/34641838/208807403-748f5c76-0426-4b36-a9c6-7c3ca5cb6f1c.png)

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
7. Receive 2% commission from both parties. (Pile up in Escrow contract and enable Withdraw)
8. Record the history.

### File Exchange Description
![OTC file flow](https://user-images.githubusercontent.com/34641838/208811260-e1464b73-a381-496b-9bbd-7c9c5dedf26d.png)

1. The app uploads the file to IPFS, registers the received ipfs url (the hash value starting with Q is important) to the 3 seconds club server, and receives a unique file ID.
2. Register a unique file ID in the OTC file transaction contract. When transacting files, you must first upload the file id to the opened OTC, and you can check the authenticity of the file on the 3 seconds club server to see if the file is uploaded to the file id.
3. When the transaction is completed, the person who purchased the file can execute the transaction completion api on the server to receive the actual file url path (the server confirms whether the transaction has been completed at this point and delivers the actual url to the contract). At the time of transaction completion, the file seller will receive tokens.
