module.exports = {
  preset: '@react-native/jest-preset',
  setupFiles: ['./jest.setup.js'],
  // test-engine*.ts 是 tsx 直接运行的引擎测试脚本 (cd rn && npx tsx test-engine.ts),
  // 不是 jest 测试, 排除避免误拾取
  testPathIgnorePatterns: [
    '/node_modules/',
    'test-engine(-live)?\\.ts$',
  ],
  // 这些包发布为 ESM, 需要被 babel 转换才能被 jest 解析
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?|@react-navigation|react-native-vector-icons|react-native-safe-area-context|react-native-gesture-handler|react-native-linear-gradient|react-native-image-picker|@react-native-async-storage/async-storage)/)',
  ],
};
