<!--
PR 标题与 commit 同格式：type(scope): 中文描述，不写任务卡号或任何内部编号。
不适用的栏目写「不涉及」，不要删掉标题。正文里不写 AI 署名（Generated with … 一类）。
最后一行必须是与 commit 作者一致的 Signed-off-by（branch-gate 会核对），把占位的姓名与邮箱换成你自己的。
-->

## 做了什么


## 为什么


## 怎么测的
- 自测：<!-- 跑了哪些命令、结果（例如 node --test "scripts/**/*.test.mjs"、各检查的 --self-test、工具自测） -->
- 真机：<!-- 在真 REAPER 上跑了什么：REAPER 版本、配置、结局与退出码；没有就写「不涉及」 -->

## 安全自查
- [ ] 默认资源目录：没有新增不经护栏的 REAPER 启动路径，`-cfgfile` 仍只由那一个常量产生，前后清单核对照常
- [ ] 进程：只结束自己启动的 PID，只处理自己 PID 的窗口
- [ ] 结局：INCOMPLETE 不当 PASS，反例仍按预期变红、原因对得上
- [ ] 隐私：结果文件、日志与本 PR 的文字里没有本机路径、用户名、主机名、已装插件清单

## DCO
- [ ] 所有 commit 均用 `git commit -s` 签名，且无 AI 署名

Signed-off-by: 姓名 <邮箱>
