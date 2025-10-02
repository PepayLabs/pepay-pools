export const ERROR_REASONS = [
    'OK',
    'PrecompileError',
    'PythError',
    'PreviewStale',
    'AOMQClamp',
    'FallbackMode',
    'ViewPathMismatch',
    'PoolError'
];
export const REGIME_BIT_VALUES = {
    AOMQ: 1 << 0,
    Fallback: 1 << 1,
    NearFloor: 1 << 2,
    SizeFee: 1 << 3,
    InvTilt: 1 << 4
};
