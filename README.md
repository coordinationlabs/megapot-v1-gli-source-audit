# Megapot Source Code Verification
The purpose of this repo is to locally generate contract creation and deployedBytecode for the BaseJackpot contract such that it can be compared against the same bytecode that can be found at the deployed contract address as presented by the block explorer, Basescan.

The BaseJackpot implementation contract is deployed at `0x26eb7396e72b8903746b0133f7692dd1fa86bc13` which can be viewed (here)[https://basescan.org/address/0x26eb7396e72b8903746b0133f7692dd1fa86bc13#code].

## Verifying Source Code
In order to verify the source code we will locally generate two forms of bytecode that can be compared to the matching bytecode on Basescan. 

### Contract Creation Code
The first form of bytecode is the Contract Creation code. The contract creation code contains any initialization parameters, the runtime code for the contract (also known as deployed bytecode), and some assorted metadata that defines what code was compiled and what tools were used to compile it

### Deployed Bytecode
The deployed bytecode for the contract is the same as the runtime code seen in the Contract Creation code however it can have some small differences. The most relevant difference for our codebase is that the deployed bytecode has immutable variables patched into the runtime code upon deploy. In the contract creation code there will be regions of code that contain a string of 0s. These regions are marking out space in the runtime code where these immutable variables will be inserted upon deployment.

### Matching the Bytecode(s)
Matching the Contract Creation code is easy, we can simply directly pull the `bytecode` artifact from our build file (can be found in `artifacts/build-info/*.json` where * = the hash of the build). The deployed bytecode is a little more involved since we need to patch in these immutable variables. In our case, the immutable variables define the address of the contract itself thus we need to fill in the regions of zeros with the address of our contract padded to 32 bytes (addresses are 20 bytes and the Ethereum Virtual Machine stores data in chunks of 32 bytes). In order to do this we created a script called `patchImmutableReferences.js` which takes the address and name of the contract you are looking to verify and patches in the address to the correct areas based on the immutable references defined during compilation.

## Running the code
1. `yarn install` all dependencies
2. Call `npm run gli-verify <contract_address> <filename>` in our case this will be `npm run gli-verify 0x26Eb7396e72b8903746b0133f7692dd1Fa86BC13 contracts/BaseJackpot.sol`
3. This will output the Contract Creation code, followed by the deployedBytecode
4. These outputs can then be compared against the same fields that can be found at the bottom of this webpage: https://basescan.org/address/0x26eb7396e72b8903746b0133f7692dd1fa86bc13#code