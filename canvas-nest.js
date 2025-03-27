// 自执行匿名函数，所有代码都在闭包内，避免污染全局命名空间
(function () {
    "use strict";
  
    // 辅助函数：判断模块是否是 ES6 模块，并返回默认导出
    function _interopDefault(mod) {
      return mod && mod.__esModule && Object.prototype.hasOwnProperty.call(mod, "default")
        ? mod["default"]
        : mod;
    }
  
    // 辅助函数：用于模块包装，接收一个函数，传入 exports 对象，并返回模块导出的对象
    function createModule(fn, exports) {
      exports = { exports: {} };
      fn(exports, exports.exports);
      return exports.exports;
    }
  
    // 模块1：计数器模块，提供一个返回自增字符串的函数
    var counter = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      var count = 1;
      // 返回一个字符串形式的自增数
      exports.default = function () {
        return "" + count++;
      };
      module.exports = exports.default;
    });
    _interopDefault(counter);
  
    // 模块2：防抖（debounce）函数模块
    var debounce = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 默认延迟时间为30ms，可通过第二个参数设置
      exports.default = function (fn, delay = 30) {
        var timeoutId = null;
        return function () {
          var context = this;
          var args = Array.prototype.slice.call(arguments);
          // 每次调用时清除上一次的定时器
          clearTimeout(timeoutId);
          // 设置新的定时器，到期后调用传入的函数
          timeoutId = setTimeout(function () {
            fn.apply(context, args);
          }, delay);
        };
      };
      module.exports = exports.default;
    });
    _interopDefault(debounce);
  
    // 模块3：与尺寸传感器相关的常量定义
    var sensorConstants = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 传感器元素ID属性
      exports.SizeSensorId = "size-sensor-id";
      // 传感器内嵌对象的样式，用于监听尺寸变化（全覆盖并不可见）
      exports.SensorStyle =
        "display:block;position:absolute;top:0;left:0;height:100%;width:100%;overflow:hidden;pointer-events:none;z-index:-1;opacity:0";
      // 传感器内嵌对象的类名
      exports.SensorClassName = "size-sensor-object";
    });
    // 使用 sensorConstants 中的属性
    var SizeSensorId = sensorConstants.SizeSensorId;
    var SensorStyle = sensorConstants.SensorStyle;
    var SensorClassName = sensorConstants.SensorClassName;
  
    // 模块4：创建传感器的实现（基于 object 标签监听尺寸变化）
    var createSensorObject = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 使用防抖函数来包装回调函数，避免频繁触发
      exports.createSensor = function (element) {
        var sensorElement = undefined;
        var callbacks = [];
  
        // 防抖回调：当触发resize事件时，依次调用所有绑定的回调函数
        var debounceCallback = debounce(function () {
          callbacks.forEach(function (cb) {
            cb(element);
          });
        });
  
        // 销毁传感器，移除事件监听和DOM元素
        var destroy = function () {
          if (sensorElement && sensorElement.parentNode) {
            sensorElement.contentDocument.defaultView.removeEventListener("resize", debounceCallback);
            sensorElement.parentNode.removeChild(sensorElement);
            sensorElement = undefined;
            callbacks = [];
          }
        };
  
        return {
          element: element,
          // 绑定一个回调函数到传感器上
          bind: function (cb) {
            if (!sensorElement) {
              // 如果父元素的position是static，则修改为relative，确保绝对定位正确
              if (getComputedStyle(element).position === "static") {
                element.style.position = "relative";
              }
              // 创建 object 元素作为传感器
              sensorElement = document.createElement("object");
              sensorElement.onload = function () {
                sensorElement.contentDocument.defaultView.addEventListener("resize", debounceCallback);
                debounceCallback();
              };
              sensorElement.setAttribute("style", SensorStyle);
              sensorElement.setAttribute("class", SensorClassName);
              sensorElement.type = "text/html";
              element.appendChild(sensorElement);
              sensorElement.data = "about:blank";
            }
            // 如果回调不存在则添加
            if (callbacks.indexOf(cb) === -1) {
              callbacks.push(cb);
            }
          },
          // 销毁传感器
          destroy: destroy,
          // 解绑指定的回调函数
          unbind: function (cb) {
            var index = callbacks.indexOf(cb);
            if (index !== -1) {
              callbacks.splice(index, 1);
            }
            // 当没有任何回调函数时，销毁传感器
            if (callbacks.length === 0 && sensorElement) {
              destroy();
            }
          }
        };
      };
    });
    // 使用 createSensorObject.createSensor
  
    // 模块5：创建传感器的实现（基于 ResizeObserver 监听尺寸变化）
    var createSensorObserver = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 使用防抖函数来包装回调函数
      exports.createSensor = function (element) {
        var observer = undefined;
        var callbacks = [];
  
        // 使用防抖函数包装resize触发回调
        var debounceCallback = debounce(function () {
          callbacks.forEach(function (cb) {
            cb(element);
          });
        });
  
        // 销毁观察者，并重置回调数组
        var destroy = function () {
          observer.disconnect();
          callbacks = [];
          observer = undefined;
        };
  
        return {
          element: element,
          // 绑定回调函数，创建 ResizeObserver 实例
          bind: function (cb) {
            if (!observer) {
              observer = new ResizeObserver(debounceCallback);
              observer.observe(element);
              debounceCallback();
            }
            if (callbacks.indexOf(cb) === -1) {
              callbacks.push(cb);
            }
          },
          destroy: destroy,
          // 解绑指定的回调函数
          unbind: function (cb) {
            var index = callbacks.indexOf(cb);
            if (index !== -1) {
              callbacks.splice(index, 1);
            }
            if (callbacks.length === 0 && observer) {
              destroy();
            }
          }
        };
      };
    });
    // 使用 createSensorObserver.createSensor
  
    // 模块6：根据环境支持选择合适的 createSensor 实现
    var createSensor = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 如果支持 ResizeObserver，则优先使用基于 ResizeObserver 的实现，否则使用 object 实现
      exports.createSensor = typeof ResizeObserver !== "undefined"
        ? createSensorObserver.createSensor
        : createSensorObject.createSensor;
    });
    // 使用 createSensor.createSensor
  
    // 模块7：辅助方法，获取和移除传感器
    var sensorHelper = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 从元素的属性中获取传感器ID，并返回已经存在的传感器实例（存储在一个私有对象中）
      var sensorStore = {};
      exports.getSensor = function (element) {
        var sensorId = element.getAttribute(SizeSensorId);
        if (sensorId && sensorStore[sensorId]) {
          return sensorStore[sensorId];
        }
        // 生成一个新的传感器ID
        var newSensorId = counter();
        element.setAttribute(SizeSensorId, newSensorId);
        var sensorInstance = createSensor.createSensor(element);
        sensorStore[newSensorId] = sensorInstance;
        return sensorInstance;
      };
  
      // 从元素上移除传感器，并清理存储
      exports.removeSensor = function (sensorInstance) {
        var sensorId = sensorInstance.element.getAttribute(SizeSensorId);
        sensorInstance.element.removeAttribute(SizeSensorId);
        sensorInstance.destroy();
        if (sensorId && sensorStore[sensorId]) {
          delete sensorStore[sensorId];
        }
      };
    });
    // 使用 sensorHelper.getSensor 和 sensorHelper.removeSensor
  
    // 模块8：对外公开绑定和清除传感器的接口
    var sensorAPI = createModule(function (module, exports) {
      Object.defineProperty(exports, "__esModule", { value: true });
      // 绑定传感器回调，返回解绑函数
      exports.bind = function (element, cb) {
        var sensorInstance = sensorHelper.getSensor(element);
        sensorInstance.bind(cb);
        return function () {
          sensorInstance.unbind(cb);
        };
      };
      // 清除元素上所有传感器
      exports.clear = function (element) {
        var sensorInstance = sensorHelper.getSensor(element);
        sensorHelper.removeSensor(sensorInstance);
      };
    });
    // sensorAPI.clear 与 sensorAPI.bind 可供外部使用
  
    // 以下部分为动画效果实现，主要利用 requestAnimationFrame 和 canvas 绘制粒子网效果
  
    // 跨浏览器兼容的 requestAnimationFrame 与 cancelAnimationFrame
    var requestFrame = window.requestAnimationFrame ||
                       window.webkitRequestAnimationFrame ||
                       window.mozRequestAnimationFrame ||
                       window.msRequestAnimationFrame ||
                       window.oRequestAnimationFrame ||
                       function (callback) {
                         return window.setTimeout(callback, 1000 / 60);
                       };
  
    var cancelFrame = window.cancelAnimationFrame ||
                      window.webkitCancelAnimationFrame ||
                      window.mozCancelAnimationFrame ||
                      window.msCancelAnimationFrame ||
                      window.oCancelAnimationFrame ||
                      window.clearTimeout;
  
    // 辅助函数：生成一个数组，数组长度为 n，内容为 [0,1,2,...,n-1]
    function range(n) {
      return new Array(n).fill(0).map(function (_, index) {
        return index;
      });
    }
  
    // 辅助函数：简易版本的 Object.assign，用于合并配置参数
    var extend = Object.assign || function (target) {
      for (var i = 1; i < arguments.length; i++) {
        var source = arguments[i];
        for (var key in source) {
          if (Object.prototype.hasOwnProperty.call(source, key)) {
            target[key] = source[key];
          }
        }
      }
      return target;
    };
  
    // 辅助函数：用于定义类的属性
    function defineProperties(target, props) {
      for (var i = 0; i < props.length; i++) {
        var descriptor = props[i];
        descriptor.enumerable = descriptor.enumerable || false;
        descriptor.configurable = true;
        if ("value" in descriptor) descriptor.writable = true;
        Object.defineProperty(target, descriptor.key, descriptor);
      }
    }
    function createClass(Constructor, protoProps, staticProps) {
      if (protoProps) defineProperties(Constructor.prototype, protoProps);
      if (staticProps) defineProperties(Constructor, staticProps);
      return Constructor;
    }
  
    // 核心类：粒子网动效类
    var ParticleNetwork = /*#__PURE__*/ (function () {
      // 构造函数，接收元素和配置参数
      function ParticleNetwork(element, options) {
        var _this = this;
        // 初始化当前实例属性
        this.el = element;
        // 默认配置：z-index、透明度、颜色、粒子颜色和粒子数量
        this.c = extend(
          { zIndex: -1, opacity: 0.5, color: "0,0,0", pointColor: "0,0,0", count: 99 },
          options
        );
        // 创建 canvas 元素并获取上下文
        this.canvas = this.newCanvas();
        this.context = this.canvas.getContext("2d");
        // 根据粒子数量生成随机粒子数据
        this.points = this.randomPoints();
        // 当前鼠标位置，默认为 null
        this.current = { x: null, y: null, max: 20000 };
        // 合并所有点（随机粒子 + 当前鼠标位置）
        this.all = this.points.concat([this.current]);
        // 绑定尺寸变化和鼠标事件
        this.bindEvent();
        // 启动动画
        this.requestFrame(this.drawCanvas);
      }
  
      // 原型方法
      createClass(ParticleNetwork, [
        {
          // 生成随机粒子数据，每个粒子包含坐标、运动方向以及最大连接距离
          key: "randomPoints",
          value: function () {
            return range(this.c.count).map(function () {
              return {
                x: Math.random() * this.canvas.width,
                y: Math.random() * this.canvas.height,
                xa: 2 * Math.random() - 1, // 水平运动速度（-1到1之间）
                ya: 2 * Math.random() - 1, // 垂直运动速度
                max: 6000 // 粒子之间连线的最大距离（平方值）
              };
            }, this);
          }
        },
        {
          // 绑定事件：监听元素尺寸变化以及全局鼠标移动与移出事件
          key: "bindEvent",
          value: function () {
            var _this2 = this;
            // 当元素尺寸变化时，更新 canvas 的大小
            sensorAPI.bind(this.el, function () {
              _this2.canvas.width = _this2.el.clientWidth;
              _this2.canvas.height = _this2.el.clientHeight;
            });
            // 保存之前的 onmousemove 事件，防止覆盖外部设置的事件
            this.onmousemove = window.onmousemove;
            // 重写 onmousemove 事件，更新当前鼠标坐标（考虑页面滚动的偏移）
            window.onmousemove = function (e) {
              _this2.current.x =
                e.clientX -
                _this2.el.offsetLeft +
                document.scrollingElement.scrollLeft;
              _this2.current.y =
                e.clientY -
                _this2.el.offsetTop +
                document.scrollingElement.scrollTop;
              if (_this2.onmousemove) {
                _this2.onmousemove(e);
              }
            };
            // 保存之前的 onmouseout 事件
            this.onmouseout = window.onmouseout;
            // 当鼠标离开窗口时，清空当前鼠标位置
            window.onmouseout = function () {
              _this2.current.x = null;
              _this2.current.y = null;
              if (_this2.onmouseout) {
                _this2.onmouseout();
              }
            };
          }
        },
        {
          // 创建 canvas 元素并插入到指定元素中
          key: "newCanvas",
          value: function () {
            // 如果父元素 position 为 static，则设置为 relative，确保 canvas 的绝对定位有效
            if (getComputedStyle(this.el).position === "static") {
              this.el.style.position = "relative";
            }
            var canvas = document.createElement("canvas");
            // 设置 canvas 的样式（覆盖整个容器，不影响鼠标事件）
            canvas.style.cssText =
              "display:block;position:absolute;top:0;left:0;height:100%;width:100%;overflow:hidden;pointer-events:none;z-index:" +
              this.c.zIndex +
              ";opacity:" +
              this.c.opacity;
            canvas.width = this.el.clientWidth;
            canvas.height = this.el.clientHeight;
            this.el.appendChild(canvas);
            return canvas;
          }
        },
        {
          // 包装 requestAnimationFrame 的调用，使其可以持续调用 drawCanvas
          key: "requestFrame",
          value: function (fn) {
            var _this3 = this;
            this.tid = requestFrame(function () {
              fn.call(_this3);
            });
          }
        },
        {
          // 主绘制方法：清除画布并绘制每个粒子及其连线效果
          key: "drawCanvas",
          value: function () {
            var context = this.context;
            var width = this.canvas.width;
            var height = this.canvas.height;
            var current = this.current;
            var points = this.points;
            var allPoints = this.all;
  
            // 清空画布
            context.clearRect(0, 0, width, height);
  
            // 遍历所有粒子
            points.forEach(function (point, i) {
              // 更新粒子的位置，根据边界反向运动
              point.x += point.xa;
              point.y += point.ya;
              point.xa *= point.x > width || point.x < 0 ? -1 : 1;
              point.ya *= point.y > height || point.y < 0 ? -1 : 1;
  
              // 绘制粒子（用 1x1 像素的矩形表示）
              context.fillStyle = "rgba(" + this.c.pointColor + ")";
              context.fillRect(point.x - 0.5, point.y - 0.5, 1, 1);
  
              // 依次检查当前粒子与后续所有点（包括鼠标位置）的连线情况
              for (var j = i + 1; j < allPoints.length; j++) {
                var other = allPoints[j];
                // 仅在两个点都有效时进行绘制
                if (other.x !== null && other.y !== null) {
                  var dx = point.x - other.x;
                  var dy = point.y - other.y;
                  var distanceSquared = dx * dx + dy * dy;
                  // 当两个点之间的距离平方小于其他点设置的最大值时，绘制连线
                  if (distanceSquared < other.max) {
                    // 修改后的代码：平滑排斥，当点过于靠近鼠标时施加排斥力
                    if (other === current) {
                        // 定义一个最小距离阈值，单位是像素（可以根据需要调整）
                        var minDist = 100; 
                        // 当点与鼠标之间的距离平方小于阈值平方时，计算排斥力
                        if (distanceSquared < minDist * minDist) {
                        // 计算排斥力大小，力随距离递减：距离越小，力越大
                        var force = (minDist * minDist - distanceSquared) / (minDist * minDist);
                        // 将点向远离鼠标的方向推进（注意方向为 (point - current)）
                        point.x += (point.x - current.x) * force * 0.05;
                        point.y += (point.y - current.y) * force * 0.05;
                        }
                    }
                    // 根据距离计算连线透明度
                    var ratio = (other.max - distanceSquared) / other.max;
                    context.beginPath();
                    context.lineWidth = ratio / 2;
                    context.strokeStyle = "rgba(" + this.c.color + "," + (ratio + 0.2) + ")";
                    context.moveTo(point.x, point.y);
                    context.lineTo(other.x, other.y);
                    context.stroke();
                  }
                }
              }
            }, this);
            // 继续下一帧绘制
            this.requestFrame(this.drawCanvas);
          }
        },
        {
          // 销毁方法：解绑事件，清除动画帧，并移除 canvas 元素
          key: "destroy",
          value: function () {
            sensorAPI.clear(this.el);
            window.onmousemove = this.onmousemove;
            window.onmouseout = this.onmouseout;
            cancelFrame(this.tid);
            if (this.canvas.parentNode) {
              this.canvas.parentNode.removeChild(this.canvas);
            }
          }
        }
      ]);
      return ParticleNetwork;
    })();
  
    // 设置类的版本号
    ParticleNetwork.version = "2.0.4";
  
    // 脚本最后部分：从当前页面中的最后一个 <script> 标签读取配置属性，
    // 并在 document.body 上实例化粒子网络动画
    var scripts = document.getElementsByTagName("script");
    var lastScript = scripts[scripts.length - 1];
    var config = {
      zIndex: lastScript.getAttribute("zIndex"),
      opacity: lastScript.getAttribute("opacity"),
      color: lastScript.getAttribute("color"),
      pointColor: lastScript.getAttribute("pointColor"),
      count: Number(lastScript.getAttribute("count")) || 99
    };
  
    // 实例化粒子网络效果，绘制在页面 body 上
    new ParticleNetwork(document.body, config);
  })();
  