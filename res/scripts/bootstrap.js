/* patch wechat devtools begin */
(() => {
    try {
        {
            // 先检查app.asar.unpacked路径有没有文件，没有会使用app.asar路径的文件
            const originalExistsSync = require("fs-extra").existsSync;
            require("fs-extra").existsSync = function (path) {
                if (path.includes("wcc.exe")) {
                    path = path.replace("wcc.exe", "wcc");
                } else if (path.includes("wcsc.exe")) {
                    path = path.replace("wcsc.exe", "wcsc");
                }
                return originalExistsSync.apply(this, [path]);
            };
        }
    } catch (error) {
        process.stderr.write(error.message);
        process.stderr.write(error.stack);
    }
})();
/* patch wechat devtools end */