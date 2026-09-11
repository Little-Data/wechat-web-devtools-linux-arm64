(() => {
    // 处理红蓝颜色通道反转的问题
    // window.__global 可能尚未就绪：不要抛异常，否则会中断被追加到同一文件的 skyline 包。
    if (window.__global) {
        window.__global.platform = 'win32'
    }
})();