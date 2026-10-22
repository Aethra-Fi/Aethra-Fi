// Inert stand-ins for the optional x402 payment packages that @coinbase/cdp-sdk imports
// (reached through RainbowKit -> Base Account). Aethra never uses x402; these only satisfy the bundler.
class Unavailable {
  constructor() {
    throw new Error("x402 is not available in this build");
  }
}
const unavailable = () => {
  throw new Error("x402 is not available in this build");
};

export const x402Client = Unavailable;
export const x402ResourceServer = Unavailable;
export const x402HTTPResourceServer = Unavailable;
export const HTTPFacilitatorClient = Unavailable;
export const ExactEvmScheme = Unavailable;
export const ExactEvmSchemeV1 = Unavailable;
export const UptoEvmScheme = Unavailable;
export const AuthCaptureEvmScheme = Unavailable;
export const BatchSettlementEvmScheme = Unavailable;
export const ExactSvmScheme = Unavailable;
export const ExactSvmSchemeV1 = Unavailable;
export const UptoSvmScheme = Unavailable;
export const BuilderCodeClientExtension = Unavailable;
export const registerExactEvmScheme = unavailable;
export const toClientEvmSigner = unavailable;
export const wrapFetchWithPayment = unavailable;
export const paymentMiddlewareFromConfig = unavailable;
export const paymentMiddlewareFromHTTPServer = unavailable;
export const bazaarResourceServerExtension = {};
export const builderCodeResourceServerExtension = {};
export const BUILDER_CODE = "";
export const BUILDER_CODE_PATTERN = /$^/;
export const BUILDER_CODE_SCHEMA = {};
export const PaymentRequirementsV1Schema = {};
export const PaymentRequirementsV2Schema = {};
