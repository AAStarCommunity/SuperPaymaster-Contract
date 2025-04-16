# CHANGES

## v0.8.02 - 2024-05-16

### 添加withdraw锁定期机制
- 添加了withdrawalDelay状态变量，默认为1小时
- 实现了两步式提款流程：先申请提款，等待锁定期后再执行
- 添加了executeWithdrawal和cancelWithdrawal函数
- 添加了相关事件、错误类型和获取函数
- 更新ISuperPaymaster接口以支持新功能

### 更改的文件
- src/v0_7/SuperPaymasterV0_7.sol
- src/interfaces/ISuperPaymaster.sol

### 可能影响的功能
- 提款流程从单步变为两步，增加了安全性
- 管理员可以设置全局的提款锁定期
- sponsor可以取消尚未执行的提款请求

## v0.8.01 - 2024-05-16

### 修正ISuperPaymaster接口文档
- 更新了ISuperPaymaster接口中registerSponsor函数的注释，将"Only callable by contract owner"修改为"Only callable by contract admin or manager"，以匹配实现中使用的onlyAdminOrManager修饰符
- 这修复了接口注释与实现之间的不一致问题

### 修复SingletonPaymasterV7继承问题
- 在SingletonPaymasterV7中为_validatePaymasterUserOp和_postOp函数添加了virtual修饰符，使它们可以被子类重写
- 从SuperPaymasterV0_7中的_disableInitializers函数中移除了override修饰符
- 添加了addBundler函数到SuperPaymasterV0_7
- 在foundry.toml中启用了via_ir=true以解决"Stack too deep"错误

### 更改的文件
- src/interfaces/ISuperPaymaster.sol
- singleton-paymaster/src/SingletonPaymasterV7.sol
- src/v0_7/SuperPaymasterV0_7.sol
- foundry.toml

### 可能影响的功能
- 接口文档更新没有功能上的变化
- 修复了合约继承关系，使SuperPaymasterV0_7可以正确重写基类函数
- 启用了via_ir编译选项，解决了堆栈深度问题
