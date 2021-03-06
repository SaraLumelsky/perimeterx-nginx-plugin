---------------------------------------------
-- PerimeterX(www.perimeterx.com) Nginx plugin
----------------------------------------------

local M = {}

function M.load(config_file)
    local _M = {}

    local px_config = require(config_file)
    local px_api = require("px.utils.pxapi").load(config_file)
    local px_logger = require("px.utils.pxlogger").load(config_file)
    local px_headers = require("px.utils.pxheaders").load(config_file)
    local px_constants = require "px.utils.pxconstants"
    local px_common_utils = require "px.utils.pxcommonutils"

    local auth_token = px_config.auth_token
    local captcha_api_path = px_constants.CAPTCHA_PATH
    local pcall = pcall

    local function split_s(str, delimiter)
        local result = {}
        local from = 1
        local delim_from, delim_to = string.find(str, delimiter, from)
        while delim_from do
            table.insert(result, string.sub(str, from, delim_from - 1))
            from = delim_to + 1
            delim_from, delim_to = string.find(str, delimiter, from)
        end
        table.insert(result, string.sub(str, from))
        return result
    end

    -- new_request_object --
    -- takes no arguments
    -- returns table
    local function new_captcha_request_object(captcha)
        local captcha_reset = {}
        captcha_reset.cid = ''
        captcha_reset.request = {}
        captcha_reset.request.firstParty = px_config.first_party_enaled or false
        captcha_reset.request.ip = px_headers.get_ip()
        captcha_reset.request.uri = ngx.var.uri
        captcha_reset.request.captchaType = px_config.captcha_provider
        captcha_reset.request.headers = px_common_utils.filter_headers(px_config.sensitive_headers, true)
        captcha_reset.pxCaptcha = captcha;
        captcha_reset.hostname = ngx.var.host;

        px_logger.debug('Captcha evaulation completed')
        return captcha_reset
    end

    function _M.process(captcha)
        if not captcha then
            px_logger.debug('No Captcha cookie present on the request');
            return -1;
        end
        px_logger.debug('Captcha cookie found, evaluating');

        local request_data = new_captcha_request_object(captcha)
        px_logger.debug('Sending Captcha API call to eval cookie');
        local start_risk_rtt = px_common_utils.get_time_in_milliseconds()
        local success, response = pcall(px_api.call_s2s, request_data, captcha_api_path, auth_token)
        ngx.ctx.risk_rtt =  px_common_utils.get_time_in_milliseconds() - start_risk_rtt
        if success then
            px_logger.debug('Captcha API response validation status: passed');
            ngx.ctx.pass_reason = 'captcha'
            return response.status
        elseif string.match(response,'timeout') then
            px_logger.debug('Captcha API response validation status: timeout');
            ngx.ctx.pass_reason = 'captcha_timeout'
            return 0
        end
        px_logger.error('Unexpected exception while evaluating Captcha cookie' .. cjson.encode(response));
        return 0;
    end

    return _M
end

return M