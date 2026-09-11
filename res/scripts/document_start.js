(() => {
    try {
        if (location.href.includes('cloudconsole') && !window._cloudConsoleFixed) {
            // fix: 云开发 -> 记录列表 -> 右键菜单项目缺少
            let env = undefined
            window._cloudConsoleFixed = true
            Object.defineProperty(window, 'env', {
                set(v) {
                    v.platform = 'linux'
                    env = v
                },
                get() {
                    return env
                }
            })
        }
    } catch (e) {
        console.error('[document_start] patch failed:', e)
    }
})();
