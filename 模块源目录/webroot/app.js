/* uv2800 WebUI 前端控制逻辑
 * 通过 KernelSU WebUI 桥接调用 webui.sh，解析 ASCII KEY=VALUE 响应并渲染界面状态。
 */
(function () {
  "use strict";

  var DEFAULT_MODULE_DIR = "/data/adb/modules/uv2800";
  var POLL_MS = 9000;
  var LOG_TAIL = 50;
  var MIN_MV = 2800;
  var MAX_MV = 3060;
  var OP_TIMEOUT_MS = 180000;

  var CODE_TEXT = {
    ok: "完成",
    busy: "另一个操作/开机初始化正在进行，请稍后重试",
    module_not_loaded: "内核模块未加载；请重启或检查模块是否启用",
    module_disabled: "模块已被禁用；如需恢复原厂，请用「恢复原厂」",
    skip_mode: "当前为原厂恢复模式；请先「重新启用」",
    test_marker: "检测到 no_adsp_write 测试标记；请先删除",
    invalid_value: "数值无效（V_s 需 2800~3060）",
    adsp_not_ready: "电量计设备指针未捕获；可重启后重试",
    write_failed: "写入失败；请查看日志",
    restore_failed: "恢复脚本失败；请查看日志/确认电量",
    restore_verify_failed: "恢复后复核不一致；请查看日志/状态",
    bind_failed: "真实电量绑定未生效；请查看日志/命名空间",
    policy_failed: "超级省电策略未应用；请查看日志（不影响 ADSP）",
    low_battery: "电量/电压过低；请先充电，或勾选风险确认",
    low_voltage: "手动 ADSP 值高于当前电池电压；可能触发钳位",
    orig_failed: "无法计算原厂值；请查看日志/DT",
    internal: "内部错误；请查看日志"
  };

  var state = {
    connected: false,
    busy: false,
    mode: "offline",
    status: null,
    vs: MIN_MV,
    dirty: false,
    logOpen: false,
    adspReadout: null
  };

  var moduleDir = resolveModuleDir();
  var pollTimer = null;
  var toastTimer = null;
  var statusLoading = false;
  var statusSeq = 0;
  var cbSeq = 0;

  function $(id) { return document.getElementById(id); }

  function hasKsu() {
    return !!(window.ksu && typeof window.ksu.exec === "function");
  }

  function isSafeDir(dir) {
    return typeof dir === "string" && dir.length > 0 && dir.length <= 200 &&
      dir.charAt(0) === "/" && dir.indexOf("..") < 0 && /^\/[A-Za-z0-9_.\/-]+$/.test(dir);
  }

  function resolveModuleDir() {
    var dir = "";
    try {
      if (window.ksu && typeof window.ksu.moduleInfo === "function") {
        var info = window.ksu.moduleInfo();
        if (info && typeof info === "object") {
          dir = info.moduleDir || info.dir || info.path || "";
        } else if (typeof info === "string") {
          var m = info.match(/"moduleDir"\s*:\s*"([^"]+)"/);
          if (m) dir = m[1];
        }
      }
    } catch (e) {
      dir = "";
    }
    return isSafeDir(dir) ? dir : DEFAULT_MODULE_DIR;
  }

  function sh(sub) {
    return "sh " + moduleDir + "/webui.sh " + sub;
  }

  function execAsync(cmd, timeoutMs) {
    timeoutMs = timeoutMs || OP_TIMEOUT_MS;
    return new Promise(function (resolve) {
      if (!hasKsu()) {
        resolve({ code: -1, out: "", err: "no_ksu" });
        return;
      }
      var name = "__uv2800_cb_" + (++cbSeq) + "_" + Date.now();
      var done = false;
      var timer = setTimeout(function () { finish(-2, "", "timeout"); }, timeoutMs);

      function finish(code, out, err) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { delete window[name]; } catch (e) { window[name] = undefined; }
        var n = Number(code);
        resolve({
          code: isFinite(n) ? n : 0,
          out: out == null ? "" : String(out),
          err: err == null ? "" : String(err)
        });
      }

      window[name] = function (a, b, c) {
        if (a && typeof a === "object") finish(a.errno, a.stdout, a.stderr);
        else finish(a, b, c);
      };

      try {
        var ret = window.ksu.exec(cmd, name);
        if (ret && typeof ret.then === "function") {
          ret.then(function (r) {
            if (r && typeof r === "object") finish(r.errno, r.stdout, r.stderr);
            else finish(0, r, "");
          })["catch"](function (e) { finish(-1, "", String(e)); });
        }
      } catch (e) {
        try {
          var out = window.ksu.exec(cmd);
          if (out && typeof out.then === "function") {
            out.then(function (r) {
              if (r && typeof r === "object") finish(r.errno, r.stdout, r.stderr);
              else finish(0, r, "");
            })["catch"](function (e2) { finish(-1, "", String(e2)); });
          } else {
            finish(0, String(out == null ? "" : out), "");
          }
        } catch (e2) {
          finish(-1, "", String((e2 && e2.message) || e2));
        }
      }
    });
  }

  function parseKV(text) {
    var out = {};
    var lines = String(text || "").split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line) continue;
      var eq = line.indexOf("=");
      if (eq <= 0) continue;
      var key = line.slice(0, eq).trim();
      if (!/^[A-Z][A-Z0-9_]*$/.test(key)) continue;
      out[key] = line.slice(eq + 1).trim();
    }
    return out;
  }

  function numOf(v) {
    if (v === undefined || v === null) return null;
    var s = String(v).trim();
    if (!s || s === "NA") return null;
    if (!/^-?\d+(\.\d+)?$/.test(s)) return null;
    var n = Number(s);
    return isFinite(n) ? n : null;
  }

  function pickNum() {
    for (var i = 0; i < arguments.length; i++) {
      var n = numOf(arguments[i]);
      if (n !== null) return n;
    }
    return null;
  }

  function derived(v) {
    // 根据关机电压 V_s 计算对应的 ADSP 终止电压：V_s < 3060 时为 2*V_s - 3060，否则等于 V_s
    var n = Number(v);
    if (!isFinite(n)) return 2540;
    var t = n < 3060 ? (2 * n - 3060) : n;
    if (t < 2000) t = 2000;
    if (t > 5000) t = 5000;
    return t;
  }

  function clamp(n, lo, hi) {
    return n < lo ? lo : (n > hi ? hi : n);
  }

  function clip(s, n) {
    s = String(s == null ? "" : s);
    return s.length > n ? s.slice(0, n) + "…" : s;
  }

  function setText(id, text) {
    var el = $(id);
    if (el) el.textContent = text;
  }

  function setGood(id, on) {
    var el = $(id);
    if (el) el.classList.toggle("good", !!on);
  }

  function each(sel, fn) {
    var list = document.querySelectorAll(sel);
    for (var i = 0; i < list.length; i++) fn(list[i]);
  }

  function toast(msg) {
    var el = $("toast");
    if (!el) return;
    el.textContent = msg;
    el.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove("show"); }, 3000);
  }

  function showError(code, text) {
    var box = $("errorBox");
    if (!box) return;
    setText("errorCode", code ? "CODE=" + code : "ERROR");
    setText("errorText", text || "未知错误");
    box.hidden = false;
  }

  function hideError() {
    var box = $("errorBox");
    if (box) box.hidden = true;
  }

  function addNotice(kind, text) {
    var host = $("notices");
    if (!host) return;
    var box = document.createElement("div");
    box.className = "notice " + kind;
    var ico = document.createElement("span");
    ico.className = "notice-ico";
    ico.textContent = kind === "ok" ? "✓" : (kind === "info" ? "i" : "!");
    var msg = document.createElement("span");
    msg.className = "notice-msg";
    msg.textContent = text;
    box.appendChild(ico);
    box.appendChild(msg);
    host.appendChild(box);
  }

  function clearNotices() {
    var host = $("notices");
    if (host) host.textContent = "";
  }

  function codeMessage(code) {
    if (!code) return "未知错误";
    return CODE_TEXT[code] || ("未知错误（" + code + "）");
  }

  function modeLabel() {
    switch (state.mode) {
      case "decoupled": return "已解容";
      case "factory": return "原厂模式";
      case "unloaded": return "未加载";
      case "disabled": return "已禁用";
      case "offline": return "未连接 KernelSU";
      default: return "未知";
    }
  }

  function profileLabel(v) {
    if (v === "cos16_17") return "ColorOS 16/17";
    if (v === "cos15") return "ColorOS 15";
    if (v === "none") return "未匹配";
    if (v === "unknown") return "未知";
    return v && v !== "NA" ? v : "—";
  }

  function routeLabel(v) {
    if (v === "standard") return "standard";
    if (v === "late-load") return "late-load";
    if (v === "unknown") return "未知";
    return "—";
  }

  function bindLabel(kv) {
    if (state.mode === "factory") return "已解绑";
    if (state.mode === "offline" || state.mode === "unknown") return "—";
    if (kv.NO_REAL_SOC === "yes") return "已关闭";
    var n = pickNum(kv.BIND_GLOBAL, kv.BIND_LAYERS);
    if (n === null) return "—";
    return n > 0 ? "已生效" : "未生效";
  }

  function policyLabel(v) {
    if (v === "applied") return "已应用";
    if (v === "restored") return "已恢复";
    return "未知";
  }

  function fccSourceLabel(v) {
    if (v === "bs" || v === "mms") return "真值";
    if (v === "display") return "显示值";
    return "";
  }

  function setBusy(b) {
    state.busy = b;
    var bar = $("busyBar");
    if (bar) bar.hidden = !b;
    syncDisabled();
  }

  function syncDisabled() {
    var connected = state.connected;
    var busy = state.busy;
    var dec = state.mode === "decoupled";
    var factory = state.mode === "factory";
    var canApply = connected && !busy && (dec || factory);
    var canRestore = connected && !busy && (dec || state.mode === "disabled");
    var canReal = connected && !busy && dec &&
      !(state.status && state.status.NO_ADSP_WRITE === "yes");

    var slider = $("voltageSlider");
    if (slider) slider.disabled = !canApply;
    each(".quick", function (el) { el.disabled = !canApply; });
    var apply = $("applyBtn");
    if (apply) apply.disabled = !canApply;
    var risk = $("riskCheck");
    if (risk) risk.disabled = !canRestore;
    var restore = $("restoreBtn");
    if (restore) restore.disabled = !canRestore;
    var sw = $("realSocSwitch");
    if (sw) sw.disabled = !canReal;
    var ss = $("superSaverSwitch");
    if (ss) ss.disabled = !connected || busy || !dec;
    var refresh = $("refreshBtn");
    if (refresh) refresh.disabled = !connected || busy;
    var refresh2 = $("refreshBtn2");
    if (refresh2) refresh2.disabled = !connected || busy;
    var logBtn = $("logBtn");
    if (logBtn) logBtn.disabled = !connected || busy;

    var canAdv = connected && !busy && dec;
    var capture = $("captureBtn");
    if (capture) capture.disabled = !canAdv;
    var readAdsp = $("readAdspBtn");
    if (readAdsp) readAdsp.disabled = !canAdv;
    var confirm = $("adspConfirm");
    if (confirm) confirm.disabled = !canAdv;
    var write = $("writeAdspBtn");
    if (write) write.disabled = !canAdv || !confirm || !confirm.checked;
  }

  function renderHeader() {
    var kv = state.status || {};
    setText("verText", kv.VERSION && kv.VERSION !== "NA" ? kv.VERSION : "—");
    var pill = $("modePill");
    if (pill) {
      var cls = "mode-pill";
      if (state.mode === "factory") cls += " factory";
      else if (state.mode === "unloaded" || state.mode === "disabled") cls += " bad";
      else if (state.mode === "offline" || state.mode === "unknown") cls += " offline";
      pill.className = cls;
    }
    setText("modeText", modeLabel());
  }

  function renderHero() {
    var kv = state.status || {};
    var real = pickNum(kv.CHIP_SOC, kv.CAPACITY);
    var cap = numOf(kv.CAPACITY);
    var volt = numOf(kv.VOLTAGE_MV);
    var temp = numOf(kv.TEMP_C);

    setText("socValue", real === null ? "—" : String(real));
    var socEl = $("socValue");
    if (socEl) socEl.classList.toggle("empty", real === null);
    setText("socPct", real === null ? "" : "%");
    var fill = $("batteryFill");
    if (fill) {
      fill.style.width = (real === null ? 0 : clamp(real, 0, 100)) + "%";
      fill.style.opacity = real === null ? "0" : "1";
    }
    setText("sysSoc", cap === null ? "—" : cap + "%");
    setText("voltText", volt === null ? "—" : (volt / 1000).toFixed(2) + " V");
    setText("tempText", temp === null ? "—" : temp + " °C");

    var dec = state.mode === "decoupled";
    var factory = state.mode === "factory";
    var vs = null;
    var adsp = null;
    if (dec) {
      vs = pickNum(kv.TARGET_EFFECTIVE, kv.PARAM_TARGET, kv.TARGET_FILE);
      adsp = numOf(kv.ADSP_DERIVED);
    } else if (factory) {
      vs = pickNum(kv.TARGET_EFFECTIVE, kv.ADSP_ORIG);
      adsp = pickNum(kv.ADSP_ORIG, kv.EXPECTED_ADSP);
    }
    setText("heroVsLabel", "关机电压");
    setText("heroVs", vs === null ? "—" : String(vs));
    setText("heroAdsp", adsp === null ? "—" : String(adsp));
    var rm = numOf(kv.BATTERY_RM);
    var fcc = numOf(kv.BATTERY_FCC);
    setText("heroRm", rm === null ? "—" : String(rm));
    setText("heroFcc", fcc === null ? "—" : String(fcc));
  }

  function renderVoltage() {
    var kv = state.status || {};
    var dec = state.mode === "decoupled";
    var factory = state.mode === "factory";

    setText("voltageValue", (dec || factory) ? String(state.vs) : "—");
    setText("derivedAdsp", (dec || factory) ? String(derived(state.vs)) : "—");
    setText("derivedUnit", (dec || factory) ? "mV" : "");

    each(".quick", function (el) {
      el.classList.toggle("active", parseInt(el.getAttribute("data-v"), 10) === state.vs);
    });

    var slider = $("voltageSlider");
    if (slider) {
      slider.value = String(state.vs);
      var p = ((state.vs - MIN_MV) / (MAX_MV - MIN_MV)) * 100;
      slider.style.setProperty("--fill", clamp(p, 0, 100) + "%");
    }

    var tag = $("voltageTag");
    if (tag) {
      var tf = numOf(kv.TARGET_FILE);
      var pt = numOf(kv.PARAM_TARGET);
      if (factory) tag.textContent = "原厂模式";
      else if (dec && tf !== null && pt !== null && tf !== pt) tag.textContent = "文件值待应用";
      else tag.textContent = "2800–3060";
    }

    var btn = $("applyBtn");
    if (btn) {
      btn.textContent = factory ? "重新启用并应用" : "应用并重跑 service.sh";
    }

    var hint = $("voltageHint");
    if (hint) {
      if (factory) hint.textContent = "当前已恢复原厂模式，如需继续使用请选择关机电压后点「重新启用并应用」";
      else if (state.mode === "unloaded") hint.textContent = "内核模块未加载，无法应用";
      else if (state.mode === "disabled") hint.textContent = "模块已禁用，无法应用";
      else if (state.mode === "offline") hint.textContent = "未连接 KernelSU，无法读取或写入";
      else hint.textContent = "修改后点击应用立即生效，若 ADSP 写入失败会在下次开机时重试";
    }
  }

  function renderRestore() {
    var kv = state.status || {};
    var volt = numOf(kv.VOLTAGE_MV);
    var cap = pickNum(kv.CHIP_SOC, kv.CAPACITY);
    var orig = numOf(kv.ADSP_ORIG);

    setText("restoreMode", state.mode === "offline" ? "—" : modeLabel());
    setText("restoreVolt", volt === null ? "—" : (volt / 1000).toFixed(2) + " V");
    setText("restoreSoc", cap === null ? "—" : cap + "%");
    setText("restoreOrigTag", orig === null ? "原值 —" : "原值 " + orig);

    var factory = state.mode === "factory";
    setText("restoreTitle", factory ? "已恢复原厂" : "恢复原厂");
    setText("restoreDesc", factory
      ? "已恢复原厂关机电压、电量显示和省电模式策略"
      : "恢复原厂关机电压、电量显示和省电模式策略");
    setText("restoreHint", orig === null
      ? "执行前需确保当前电池电压 > 原值 mV"
      : "执行前需确保当前电池电压 > " + orig + " mV");
    var btn = $("restoreBtn");
    if (btn) btn.textContent = factory ? "已恢复原厂" : "恢复原厂";
  }

  function renderFeatures() {
    var kv = state.status || {};
    var noReal = kv.NO_REAL_SOC === "yes";
    var realOn = state.mode === "decoupled" && !noReal;
    var sw = $("realSocSwitch");
    if (sw) {
      sw.classList.toggle("on", realOn);
      sw.setAttribute("aria-checked", realOn ? "true" : "false");
    }
    var hint = $("realSocHint");
    if (hint) {
      if (state.mode === "factory") hint.textContent = "原厂模式下无法使用该功能";
      else if (state.mode === "unloaded") hint.textContent = "模块未加载，无法使用该功能";
      else if (state.mode === "disabled") hint.textContent = "模块已禁用，无法使用该功能";
      else if (state.mode === "offline") hint.textContent = "未连接 KernelSU";
      else hint.textContent = noReal
        ? "关：使用官方平滑电量"
        : "开：已去除官方平滑电量显示";
    }

    var policyOn = state.mode === "decoupled" && kv.NO_POLICY !== "yes";
    var ss = $("superSaverSwitch");
    if (ss) {
      ss.classList.toggle("on", policyOn);
      ss.setAttribute("aria-checked", policyOn ? "true" : "false");
    }
    if (state.mode === "factory") {
      setText("superSaverHint", "原厂模式下无法使用该功能");
    } else if (state.mode === "unloaded") {
      setText("superSaverHint", "模块未加载，无法使用该功能");
    } else if (state.mode === "disabled") {
      setText("superSaverHint", "模块已禁用，无法使用该功能");
    } else if (state.mode === "offline") {
      setText("superSaverHint", "未连接 KernelSU");
    } else if (kv.NO_POLICY === "yes") {
      setText("superSaverHint", "关：允许系统在 1% 时进入超级省电");
    } else {
      setText("superSaverHint", "开：已禁止系统在 1% 时进入超级省电");
    }
  }

  function renderGrid() {
    var kv = state.status || {};
    var adspRead = numOf(kv.ADSP_READ);
    var vbat = numOf(kv.VBAT_UV);
    var orig = numOf(kv.ADSP_ORIG);
    var adspState = numOf(kv.ADSP_STATE);
    var cc = numOf(kv.CC);
    var counts = numOf(kv.COUNTS);
    var temp = numOf(kv.TEMP_C);

    setText("adspActual", adspRead === null ? "—" : adspRead + " mV");
    setText("vbatCell", vbat === null ? "—" : vbat + " mV");
    setText("origCell", orig === null ? "—" : orig + " mV");
    setText("adspStateCell", adspState === null ? "—" : adspState + " mV");
    setText("profileCell", profileLabel(kv.PROFILE));
    setText("routeCell", routeLabel(kv.ROUTE));
    setText("bindCell", bindLabel(kv));
    setText("policyCell", policyLabel(kv.POLICY));
    setText("rmCell", numOf(kv.BATTERY_RM) === null ? "—" : String(numOf(kv.BATTERY_RM)) + " mAh");
    var fcc = numOf(kv.BATTERY_FCC);
    var fccTag = fccSourceLabel(kv.BATTERY_FCC_SRC);
    setText("fccCell", fcc === null ? "—" : String(fcc) + " mAh" + (fccTag ? "（" + fccTag + "）" : ""));
    setText("cycleCell", (cc === null ? "—" : String(cc)) + " / " + (counts === null ? "—" : String(counts)));
    setText("tempCell", temp === null ? "—" : temp + " °C");

    setGood("adspActual", kv.ADSP_MISMATCH === "0");
    setGood("bindCell", kv.BIND_MISMATCH === "0" && kv.NO_REAL_SOC !== "yes" && state.mode === "decoupled");
    setGood("policyCell", kv.POLICY === "applied");
  }

  function renderAdvanced() {
    var v = state.adspReadout;
    setText("adspReadout", v ? v + " mV" : "—");
  }

  function setAdspReadout(v) {
    state.adspReadout = (v && v !== "NA") ? String(v) : null;
    renderAdvanced();
  }

  function renderNotices() {
    clearNotices();
    if (!state.connected || state.mode === "offline") {
      addNotice("error", "未连接 KernelSU：请在 KernelSU / APatch 管理器中打开本页面，当前不会执行任何命令");
      return;
    }

    var kv = state.status || {};
    var problems = 0;

    if (state.mode === "unloaded") {
      addNotice("warn", "内核模块未加载：部分模块功能不可用，请重启或检查模块是否启用");
      problems++;
    } else if (state.mode === "disabled") {
      addNotice("warn", "模块已被禁用：仅「恢复原厂」可用，如需继续使用请先在管理器中启用模块");
      problems++;
    } else if (state.mode === "factory") {
      addNotice("info", "当前为原厂模式：模块已停用");
    }

    if (kv.STALE_LOCK === "yes") {
      addNotice("warn", "上次操作可能中断（陈旧锁），请刷新状态后重试");
      problems++;
    } else if (kv.LOCK === "yes") {
      addNotice("warn", "另一个操作正在进行（webui 锁被占用）");
      problems++;
    }

    if (kv.NO_ADSP_WRITE === "yes") {
      addNotice("warn", "检测到 no_adsp_write 测试标记：写操作会被拒绝，请先删除该文件");
      problems++;
    }
    if (kv.ADSP_ORIG_BAD === "yes") {
      addNotice("warn", "原值记录异常（adsp_orig.bad）：请查看日志");
      problems++;
    }
    if (kv.BATTERY_LOW === "1") {
      addNotice("error", "电量/电压过低：恢复原厂前请先充电，并勾选风险确认");
      problems++;
    }
    if (kv.ADSP_MISMATCH === "1") {
      addNotice("warn", "ADSP 实际值与期望不一致（可能 uv_dev 未捕获或写入失败），重启后会自动重试");
      problems++;
    }
    if (kv.BIND_MISMATCH === "1") {
      addNotice("warn", "真实电量绑定状态异常：请查看日志与命名空间");
      problems++;
    }
    if (kv.PROFILE === "none" || kv.PROFILE === "unknown") {
      addNotice("warn", "内核 profile 未匹配或未知：ADSP 相关功能可能不可用，操作结果以后端复核为准");
      problems++;
    }

    var tf = numOf(kv.TARGET_FILE);
    var pt = numOf(kv.PARAM_TARGET);
    if (state.mode === "decoupled" && tf !== null && pt !== null && tf !== pt) {
      addNotice("warn", "目标文件与内核参数不一致：请重新应用");
      problems++;
    }

    if (problems === 0 && state.mode === "decoupled" &&
        kv.ADSP_MISMATCH === "0" && kv.BIND_MISMATCH === "0" && kv.POLICY === "applied") {
      addNotice("ok", "ADSP 实际值与目标一致，解耦正常");
    }
  }

  function renderAll() {
    renderHeader();
    renderHero();
    renderVoltage();
    renderRestore();
    renderFeatures();
    renderGrid();
    renderAdvanced();
    renderNotices();
    syncDisabled();
  }

  function applyStatus(text) {
    if (state.busy) return;
    var kv = parseKV(text);
    if (!kv.MODE && !kv.RESULT) {
      showError("bad_status", "无法解析 webui.sh status 输出（len=" + String(text || "").length +
        "）：" + clip(String(text || ""), 300));
      return;
    }
    state.connected = true;
    state.status = kv;
    state.mode = kv.MODE || "unknown";
    if (state.mode === "decoupled" && !state.dirty) {
      var eff = pickNum(kv.TARGET_EFFECTIVE, kv.PARAM_TARGET, kv.TARGET_FILE);
      if (eff !== null && eff >= MIN_MV && eff <= MAX_MV) state.vs = eff;
    }
    renderAll();
  }

  function goOffline() {
    invalidateStatus();
    state.connected = false;
    state.status = null;
    state.mode = "offline";
    renderAll();
  }

  function waitStatus(seq) {
    var startedAt = Date.now();
    function poll() {
      if (seq !== statusSeq) return;
      if (Date.now() - startedAt > 20000) {
        statusLoading = false;
        showError("bad_status", "status 超时，请重试");
        return;
      }
      execAsync(sh("op-result status"), 5000).then(function (r) {
        if (seq !== statusSeq) return;
        var kv = parseKV(r.out);
        if (kv.RESULT === "busy") {
          setTimeout(poll, 400);
          return;
        }
        statusLoading = false;
        if (!kv.RESULT) {
          showError("bad_status", "status 无输出：code=" + r.code + " err=" + clip(r.err || "none", 300));
          return;
        }
        applyStatus(r.out);
      });
    }
    poll();
  }

  function invalidateStatus() {
    statusSeq++;
    statusLoading = false;
  }

  function loadStatus() {
    if (!hasKsu()) { goOffline(); return; }
    if (statusLoading) return;
    statusLoading = true;
    var seq = ++statusSeq;
    // 连 status 也放后台：刷新/轮询时同步桥仍会占住 WebView，
    // 用 run-bg 只启动子进程，再短轮询 op-result。
    execAsync(sh("run-bg status status"), 5000).then(function (r) {
      if (seq !== statusSeq) return;
      if (r.code === -1) {
        statusLoading = false;
        goOffline();
        return;
      }
      var kv = parseKV(r.out);
      if (kv.CODE !== "started") {
        statusLoading = false;
        showError("bad_status", "status 启动失败：code=" + r.code + " " + clip(r.err || r.out || "无输出", 300));
        return;
      }
      waitStatus(seq);
    });
  }

  function handleResult(kv, label) {
    var code = kv.CODE || "";
    var result = kv.RESULT || "";
    var verify = kv.VERIFY || "";
    if (result === "ok") {
      hideError();
      toast(label + "完成" + (verify === "ok" ? "（复核通过）" : ""));
      return;
    }
    var prefix = result === "warn" ? "操作完成但复核异常"
      : (result === "busy" ? "操作未执行：系统忙碌" : "操作失败");
    var detail = codeMessage(code) +
      (verify ? " · VERIFY=" + verify : "") +
      (kv.DETAIL ? " · " + clip(kv.DETAIL, 200) : "");
    showError(code || "unknown", prefix + "：" + detail);
    toast((result === "busy" ? "忙碌" : (result === "warn" ? "复核异常" : "失败")) +
      (code ? "：CODE=" + code : ""));
  }

  function waitOp(label) {
    var startedAt = Date.now();
    return new Promise(function (resolve) {
      function poll() {
        if (Date.now() - startedAt > OP_TIMEOUT_MS) {
          setBusy(false);
          showError("timeout", "操作超时，请查看日志");
          if (hasKsu()) loadStatus();
          resolve(null);
          return;
        }
        execAsync(sh("op-result op"), 5000).then(function (res) {
          var kv = parseKV(res.out);
          if (kv.RESULT === "busy") {
            setTimeout(poll, 600);
            return;
          }
          setBusy(false);
          if (!kv.RESULT) {
            showError("exec_failed", "操作结果读取失败（exit=" + res.code + "）" +
              clip(res.err || res.out || "无输出", 400));
            if (hasKsu()) loadStatus();
            resolve(null);
            return;
          }
          handleResult(kv, label);
          if (state.logOpen) loadLog();
          if (hasKsu()) loadStatus();
          resolve(kv);
        });
      }
      poll();
    });
  }

  function runOp(sub, label) {
    if (!state.connected || state.busy) return Promise.resolve(null);
    if (!hasKsu()) { goOffline(); return Promise.resolve(null); }
    hideError();
    setBusy(true);
    // 作废点击前已发出的 status 请求，避免旧状态在操作中把开关视觉回滚。
    invalidateStatus();
    // run-bg 只启动子进程并立即返回；真正命令在后台执行，
    // 避免 ksu.exec 同步桥把 WebView 主线程卡住整个命令时长。
    return execAsync(sh("run-bg op " + sub), 5000).then(function (res) {
      if (res.code === -1) {
        setBusy(false);
        showError("no_ksu", "KernelSU 执行接口不可用");
        return null;
      }
      var kv = parseKV(res.out);
      if (kv.CODE !== "started") {
        setBusy(false);
        showError("exec_failed", "后台任务启动失败（exit=" + res.code + "）" +
          clip(res.err || res.out || "无输出", 400));
        if (hasKsu()) loadStatus();
        return null;
      }
      return waitOp(label);
    })["catch"](function (e) {
      setBusy(false);
      showError("internal", String((e && e.message) || e));
      if (hasKsu()) loadStatus();
      return null;
    });
  }

  function applyVoltage() {
    if (!state.connected) { toast("未连接 KernelSU"); return; }
    if (state.busy) return;
    if (state.mode !== "decoupled" && state.mode !== "factory") {
      toast("当前模式不可应用");
      return;
    }
    var raw = String(state.vs);
    if (!/^\d{1,4}$/.test(raw)) { toast("数值无效：请输入 2800–3060"); return; }
    var v = parseInt(raw, 10);
    if (!(v >= MIN_MV && v <= MAX_MV)) { toast("数值无效：V_s 需 2800–3060"); return; }
    state.dirty = false;
    if (state.mode === "factory") {
      runOp("enable " + v, "重新启用 " + v + " mV");
    } else {
      runOp("apply " + v, "应用 " + v + " mV");
    }
  }

  function doRestore() {
    if (!state.connected) { toast("未连接 KernelSU"); return; }
    if (state.busy) return;
    if (state.mode === "factory") { toast("已经是原厂恢复模式"); return; }
    if (state.mode !== "decoupled" && state.mode !== "disabled") {
      toast("当前模式不可恢复原厂");
      return;
    }
    var risk = $("riskCheck");
    if (risk && !risk.checked) { toast("请先勾选「我已知晓风险」"); return; }
    if (!window.confirm("确认恢复原厂？\n\n将写回电量计原值，退出解耦，并恢复超级省电策略与官方电量显示")) return;
    var low = !!(state.status && state.status.BATTERY_LOW === "1");
    runOp("restore" + (low ? " --force" : ""), "恢复原厂");
  }

  function toggleRealSoc() {
    if (!state.connected) { toast("未连接 KernelSU"); return; }
    if (state.busy) return;
    if (state.mode !== "decoupled") { toast("当前模式不可切换"); return; }
    var next = (state.status && state.status.NO_REAL_SOC === "yes") ? 1 : 0;
    // 先乐观更新开关，命令在后台异步执行；失败时 runOp 会重新拉 status 回滚。
    if (state.status) {
      state.status.NO_REAL_SOC = next ? "no" : "yes";
      renderFeatures();
      syncDisabled();
    }
    runOp("set-real-soc " + next, next ? "开启真实电量" : "关闭真实电量");
  }

  function togglePolicy() {
    if (!state.connected) { toast("未连接 KernelSU"); return; }
    if (state.busy) return;
    if (state.mode !== "decoupled") { toast("当前模式不可切换"); return; }
    var next = (state.status && state.status.NO_POLICY === "yes") ? "on" : "off";
    if (state.status) {
      state.status.NO_POLICY = next === "on" ? "no" : "yes";
      renderFeatures();
      syncDisabled();
    }
    runOp("policy " + next, next === "on" ? "开启禁止 1% 超级省电" : "关闭禁止 1% 超级省电");
  }

  function loadLog() {
    var pre = $("logText");
    if (!pre) return;
    if (!state.connected) { pre.textContent = "未连接 KernelSU"; return; }
    // 只用异步 exec，避免同步调用阻塞 WebView 主线程。
    execAsync(sh("log " + LOG_TAIL), 20000).then(function (r) {
      if (r.out) { pre.textContent = r.out; return; }
      pre.textContent = "读取日志失败：code=" + r.code + " " + (r.err || "无输出");
    });
  }

  function toggleLog() {
    var box = $("logBox");
    if (!box) return;
    if (!box.hidden) { box.hidden = true; state.logOpen = false; return; }
    box.hidden = false;
    state.logOpen = true;
    loadLog();
  }

  function refreshStatus() {
    if (!state.connected || state.busy) return;
    hideError();
    loadStatus();
    if (state.logOpen) loadLog();
    toast("已刷新状态");
  }

  function captureDev() {
    if (!state.connected || state.busy) return;
    if (state.mode !== "decoupled") { toast("当前模式不可捕获"); return; }
    runOp("capture-dev", "捕获设备指针").then(function (kv) {
      if (kv && kv.ADSP_READ) setAdspReadout(kv.ADSP_READ);
    });
  }

  function readAdsp() {
    if (!state.connected || state.busy) return;
    if (state.mode !== "decoupled") { toast("当前模式不可读取"); return; }
    runOp("read-adsp", "读取 ADSP").then(function (kv) {
      if (kv && kv.ADSP_READ) setAdspReadout(kv.ADSP_READ);
    });
  }

  function writeAdsp() {
    if (!state.connected || state.busy) return;
    if (state.mode !== "decoupled") { toast("当前模式不可写入"); return; }
    var input = $("adspInput");
    var confirm = $("adspConfirm");
    if (!confirm || !confirm.checked) { toast("请先勾选风险确认"); return; }
    var raw = input ? String(input.value).trim() : "";
    if (!/^\d{1,4}$/.test(raw)) { toast("请输入 2000–5000 的整数"); return; }
    var v = parseInt(raw, 10);
    if (v < 2000 || v > 5000) { toast("ADSP 范围 2000–5000 mV"); return; }
    if (!window.confirm("确认手动写入 ADSP = " + v + " mV？\n这会影响电量计 0% 位置，日常请用 V_s 派生")) return;
    runOp("write-adsp " + v, "写入 ADSP " + v + " mV").then(function (kv) {
      if (kv && kv.ADSP_READ) setAdspReadout(kv.ADSP_READ);
      if (kv && kv.RESULT === "ok") { if (input) input.value = ""; if (confirm) confirm.checked = false; syncDisabled(); }
    });
  }

  function bindEvents() {
    var slider = $("voltageSlider");
    if (slider) {
      slider.addEventListener("input", function () {
        var v = parseInt(slider.value, 10);
        if (isNaN(v)) return;
        state.vs = clamp(v, MIN_MV, MAX_MV);
        state.dirty = true;
        renderVoltage();
        syncDisabled();
      });
    }

    each(".quick", function (btn) {
      btn.addEventListener("click", function () {
        var v = parseInt(btn.getAttribute("data-v"), 10);
        if (isNaN(v)) return;
        state.vs = clamp(v, MIN_MV, MAX_MV);
        state.dirty = true;
        renderVoltage();
        syncDisabled();
      });
    });

    var apply = $("applyBtn");
    if (apply) apply.addEventListener("click", applyVoltage);
    var restore = $("restoreBtn");
    if (restore) restore.addEventListener("click", doRestore);
    var sw = $("realSocSwitch");
    if (sw) sw.addEventListener("click", toggleRealSoc);
    var ss = $("superSaverSwitch");
    if (ss) ss.addEventListener("click", togglePolicy);

    var refresh = $("refreshBtn");
    if (refresh) refresh.addEventListener("click", refreshStatus);
    var refresh2 = $("refreshBtn2");
    if (refresh2) refresh2.addEventListener("click", refreshStatus);

    var logBtn = $("logBtn");
    if (logBtn) logBtn.addEventListener("click", toggleLog);

    var capture = $("captureBtn");
    if (capture) capture.addEventListener("click", captureDev);
    var readAdspBtn = $("readAdspBtn");
    if (readAdspBtn) readAdspBtn.addEventListener("click", readAdsp);
    var writeAdspBtn = $("writeAdspBtn");
    if (writeAdspBtn) writeAdspBtn.addEventListener("click", writeAdsp);
    var adspConfirm = $("adspConfirm");
    if (adspConfirm) adspConfirm.addEventListener("change", syncDisabled);
    var adspInput = $("adspInput");
    if (adspInput) adspInput.addEventListener("input", syncDisabled);

    var closeLog = $("closeLog");
    if (closeLog) closeLog.addEventListener("click", function () {
      var box = $("logBox");
      if (box) box.hidden = true;
      state.logOpen = false;
    });

    var errorClose = $("errorClose");
    if (errorClose) errorClose.addEventListener("click", hideError);
  }

  function startPoll() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(function () {
      if (document.hidden || state.busy) return;
      if (!hasKsu()) return;
      loadStatus();
    }, POLL_MS);
  }

  function init() {
    bindEvents();
    if (hasKsu()) {
      state.connected = true;
      state.mode = "unknown";
      renderAll();
      loadStatus();
      startPoll();
    } else {
      goOffline();
    }
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden && !state.busy && state.connected) loadStatus();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
