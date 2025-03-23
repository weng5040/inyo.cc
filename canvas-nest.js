// 自执行匿名函数，使用严格模式
!function() {
    "use strict";

    // 模块加载工具函数
    function e(e) { /*...*/ } // CommonJS 模块加载辅助函数
    function t(e,t) { /*...*/ } // 模块定义函数

    // 生成唯一ID的模块 [[4]](#__4)
    var n = t(function(e,t) {
        Object.defineProperty(t,"__esModule",{value:!0});
        var n=1;
        t.default=function(){return""+n++},e.exports=t.default
    });
    e(n);

    // 防抖函数模块 [[6]](#__6)
    var o = t(function(e,t) {
        Object.defineProperty(t,"__esModule",{value:!0}),
        t.default=function(e){
            var t=arguments.length>1&&void 0!==arguments[1]?arguments[1]:30,
                n=null;
            return function(){
                // 使用闭包保存定时器
                for(var o=this,i=arguments.length,r=Array(i),a=0;a<i;a++)r[a]=arguments[a];
                clearTimeout(n),
                n=setTimeout(function(){e.apply(o,r)},t)
            }
        },
        e.exports=t.default
    });
    e(o);

    // 尺寸传感器常量定义 [[7]](#__7)
    var i = t(function(e,t){
        Object.defineProperty(t,"__esModule",{value:!0});
        t.SizeSensorId="size-sensor-id", // 传感器ID属性名
        t.SensorStyle="display:block;position:absolute;...", // 传感器样式
        t.SensorClassName="size-sensor-object" // 传感器类名
    });
    e(i);

    // 传感器创建逻辑（兼容ResizeObserver和传统方案）[[6]](#__6)
    var r = t(function(e,t){ /*...*/ }); // 传统 object 元素方案
    var a = t(function(e,t){ /*...*/ }); // 现代 ResizeObserver 方案
    var s = t(function(e,t){ /*...*/ }); // 自动选择传感器方案

    // 传感器管理模块 [[7]](#__7)
    var u = t(function(e,t){
        Object.defineProperty(t,"__esModule",{value:!0}),
        t.removeSensor=t.getSensor=void 0;
        var o,r=(o=n)&&o.__esModule?o:{default:o};
        var a={};
        t.getSensor=function(e){
            // 获取或创建传感器实例
            var t=e.getAttribute(i.SizeSensorId);
            if(t&&a[t])return a[t];
            var n=(0,r.default)();
            e.setAttribute(i.SizeSensorId,n);
            var o=(0,s.createSensor)(e);
            return a[n]=o,o
        },
        t.removeSensor=function(e){ /*...*/ }
    });

    // 传感器绑定/解绑接口 [[7]](#__7)
    var c = t(function(e,t){
        Object.defineProperty(t,"__esModule",{value:!0}),
        t.clear=t.bind=void 0;
        t.bind=function(e,t){ /*...*/ }, // 绑定传感器回调
        t.clear=function(e){ /*...*/ }  // 清除传感器
    });

    // 动画工具函数
    var l=c.clear,d=c.bind,
        v=window.requestAnimationFrame||/*...*/,
        f=window.cancelAnimationFrame||/*...*/;

    // 粒子系统核心类 [[2]](#__2)
    var y=function(){
        function e(t,n){
            // 初始化配置
            this.el=t; // 目标DOM元素
            this.c=h({ // 合并默认配置
                zIndex:-1,
                opacity:.5,
                color:"0,0,0",
                pointColor:"0,0,0",
                count:99
            },n);

            // 创建画布
            this.canvas=this.newCanvas();
            this.context=this.canvas.getContext("2d");

            // 初始化粒子
            this.points=this.randomPoints();
            this.current={x:null,y:null,max:2e4};
            this.all=this.points.concat([this.current]);

            // 绑定事件
            this.bindEvent();

            // 启动动画
            this.requestFrame(this.drawCanvas)
        }

        // 类方法定义...
    };

    // 创建粒子系统实例
    new y(document.body,{
        zIndex: /* 从script标签获取配置 */,
        opacity: /* ... */,
        color: /* ... */,
        pointColor: /* ... */,
        count: /* ... */
    });
}();