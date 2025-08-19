// extractImmutable.js
import fs from 'fs';

const filePath = 'artifacts/build-info/e01fc4b1d6d91c1d6239973097fcaaad.json';
const addressToVerify = process.argv[2];
const fileToVerify = process.argv[3];

if (!addressToVerify || !fileToVerify) {
  console.log("Current arguments:", process.argv);
  console.error("Usage: node extractImmutable.js <address-to-verify> <file-to-verify>");
  console.error("Example: node extractImmutable.js 0x26Eb7396e72b8903746b0133f7692dd1Fa86BC13 contracts/BaseJackpot.sol");
  process.exit(1);
}

const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
const contracts = data?.output?.contracts || {};

for (const [file, ctGroup] of Object.entries(contracts)) {
  if (file == fileToVerify) {
    for (const [ctName, details] of Object.entries(ctGroup)) {
      // Remove 0x prefix if present and ensure lowercase
      const cleanAddress = addressToVerify.replace(/^0x/, '').toLowerCase();
      // Pad to 64 characters (32 bytes) for immutable references
      const paddedAddress = cleanAddress.padStart(64, '0');
      
      const immutableReferences = ctGroup[ctName].evm.deployedBytecode.immutableReferences;
      console.log(`Processing contract: ${ctName} from file: ${file}`);
      console.log(`Address to verify: ${addressToVerify} -> ${paddedAddress}`);
      
      let bytecode = ctGroup[ctName].evm.deployedBytecode.object
      
      for (const [refName, refDetails] of Object.entries(immutableReferences)) {
        for (const ref of refDetails) {
          const startPos = ref.start * 2; // Convert byte position to hex string position (2 chars per byte)
          const length = ref.length * 2; // Convert byte length to hex string length
          
          console.log(`Replacing at position ${ref.start} (hex pos ${startPos}) with length ${ref.length} (hex length ${length})`);
          console.log(`Original bytecode length: ${bytecode.length}`);
          
          // Replace the bytes at the specified position with the lowercase address
          bytecode = bytecode.slice(0, startPos) + paddedAddress + bytecode.slice(startPos + length);
        }
        console.log(`  Updated bytecode after processing ${refName}`);
      }
      
      console.log('Contract creation code: \n', ctGroup[ctName].evm.bytecode.object);
      console.log('------------------------------------------------------------------------------------------------');
      console.log('Final patched deployed bytecode: \n', '0x' + bytecode);
    }
  }
}
