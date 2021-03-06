---------------------------------------------
-- PerimeterX(www.perimeterx.com) Nginx plugin
----------------------------------------------
local M = {}

function M.load(config_file)
    local _M = {}

    local http = require "resty.http"
    local os = require "os"
    local cjson = require "cjson"
    local tostring = tostring
    local ngx_time = ngx.time
    local ngx_req_set_header = ngx.req.set_header
    local ngx_req_set_uri = ngx.req.set_uri

    local px_config = require(config_file)
    local px_logger = require("px.utils.pxlogger").load(config_file)
    local px_headers = require("px.utils.pxheaders").load(config_file)
    local buffer = require "px.utils.pxbuffer"
    local px_constants = require "px.utils.pxconstants"
    local px_common_utils = require "px.utils.pxcommonutils"
    local pcall = pcall


    local auth_token = px_config.auth_token
    local ssl_enabled = px_config.ssl_enabled
    local px_server = px_config.base_url

    -- Submit is the function to create the HTTP connection to the PX collector and POST the data
    function _M.submit(data, path)

        local px_port = px_config.px_port
        local px_debug = px_config.px_debug
        -- timeout in milliseconds
        local timeout = px_config.client_timeout
        -- create new HTTP connection
        local httpc = http.new()
        httpc:set_timeout(timeout)
        local ok, err = httpc:connect(px_server, px_port)
        if not ok then
            px_logger.error("HTTPC connection error: " .. err)
        end
        -- Perform SSL/TLS handshake
        if ssl_enabled == true then
            local session, err = httpc:ssl_handshake()
            if not session then
                px_logger.error("HTTPC SSL handshare error: " .. err)
            end
        end
        -- Perform the HTTP requeset
        local res, err = httpc:request({
            path = path,
            method = "POST",
            body = data,
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. auth_token
            }
        })
        if not res then
            px_logger.error("Failed to make HTTP POST: " .. err)
            error("Failed to make HTTP POST: " .. err)
        elseif res.status ~= 200 then
            px_logger.debug("Non 200 response code: " .. res.status)
            error("Non 200 response code: " .. res.status)
        else
            px_logger.debug("POST response status: " .. res.status)
        end

        -- Must read the response body to clear the buffer in order for set keepalive to work properly.
        local body = res:read_body()

        -- Check for connection reuse
        if px_debug == true then
            local times, err = httpc:get_reused_times()
            if not times then
                px_logger.error("Error getting reuse times: " .. err)
            else
                px_logger.debug("Reused conn times: " .. times)
            end
        end
        -- set keepalive to ensure connection pooling
        local ok, err = httpc:set_keepalive()
        if not ok then
            px_logger.error("Failed to set keepalive: " .. err)
        end
    end

    function _M.send_to_perimeterx(event_type, details)
        local buflen = buffer.getBufferLength();
        local maxbuflen = px_config.px_maxbuflen;
        local full_url = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.uri;

        if event_type == 'page_requested' and not px_config.send_page_requested_activity then
            return
        end

        if px_config.additional_activity_handler ~= nil then
            px_logger.debug("additional_activity_handler was triggered");
            px_config.additional_activity_handler(event_type, ngx.ctx, details)
        end

        local pxdata = {};
        pxdata['type'] = event_type;
        pxdata['headers'] = px_common_utils.filter_headers(px_config.sensitive_headers, false)
        pxdata['url'] = full_url;
        pxdata['px_app_id'] = px_config.px_appId
        pxdata['timestamp'] = tostring(ngx_time())
        pxdata['socket_ip'] = px_headers.get_ip()

        details['module_version'] = px_constants.MODULE_VERSION
        details['risk_rtt'] = 0
        details['cookie_origin'] = ngx.ctx.px_cookie_origin
        if ngx.ctx.risk_rtt then
            details['risk_rtt'] = math.ceil(ngx.ctx.risk_rtt)
            px_logger.enrich_log('pxrtt', math.ceil(ngx.ctx.risk_rtt))
        end

        if ngx.ctx.vid then
            pxdata['vid'] = ngx.ctx.vid
            px_logger.enrich_log('pxvid', ngx.ctx.vid)
        end

        if ngx.ctx.uuid then
            details['client_uuid'] = ngx.ctx.uuid
            px_logger.enrich_log('pxuuid',ngx.ctx.uuid)
        end

        if ngx.ctx.px_cookie then
            details['px_cookie'] = ngx.ctx.px_cookie
        end

        if ngx.ctx.px_cookie then
            details['px_cookie_hmac'] = ngx.ctx.px_cookie_hmac
        end

        if event_type == 'page_requested' then
            px_logger.debug("Sent page requested acitvity")
            details['pass_reason'] = ngx.ctx.pass_reason
            px_logger.enrich_log('pxpass', details.pass_reason)
        end

        pxdata['details'] = details;

        buffer.addEvent(pxdata)
        -- Perform the HTTP action
        if buflen >= maxbuflen then
            pcall(_M.submit, buffer.dumpEvents(), px_constants.ACTIVITIES_PATH);
        end
    end

    function _M.send_enforcer_telmetry(details)
        local enforcer_telemetry = {}

        details.os_name = jit.os
        details.node_name = os.getenv("HOSTNAME")
        details.module_version = px_constants.MODULE_VERSION

        enforcer_telemetry.type = 'enforcer_telemetry'
        enforcer_telemetry.px_app_id = px_config.px_appId
        enforcer_telemetry.timestamp = tostring(ngx_time())
        enforcer_telemetry.details = details

        -- Perform the HTTP action
        _M.submit(cjson.encode(enforcer_telemetry), px_constants.TELEMETRY_PATH);
    end

    function _M.forward_to_perimeterx(server, port_overide)
        -- Attach real ip from the enforcer
        ngx_req_set_header(px_constants.ENFORCER_TRUE_IP_HEADER, px_headers.get_ip())
        ngx_req_set_header(px_constants.FIRST_PARTY_HEADER, '1')

        -- change the host so BE knows where to serve the request
        ngx_req_set_header('host', server)

        local port = ngx.var.scheme == 'http' and '80' or '443'
        if port_overide ~= nil then
            px_logger.debug('Overrding port ' .. port ..  ' => ' .. port_overide)
            port =  port_overide
        end
        px_logger.debug("Using " .. ngx.var.scheme .. " port " .. port)
        local httpc = http.new()

        httpc:set_timeout(2000)

        local ok, err = httpc:connect(server, port)

        if not ok then
            ngx.log(ngx.ERR, err)
            return
        end

        if port == '443' and ssl_enabled then
            if ssl_enabled == true then
                local session, err = httpc:ssl_handshake()
                if not session then
                    px_logger.error("HTTPC SSL handshare error: " .. err)
                end
            end
        end

        httpc:proxy_response(httpc:proxy_request())
        httpc:set_keepalive()
    end

    function _M.reverse_px_client()
        if not px_config.first_party_enabled then
            ngx.header["Content-Type"] = 'application/javascript';
            ngx.say('')
            ngx.exit(ngx.OK)
            return
        end

        local px_request_uri = "/" .. px_config.px_appId .. "/main.min.js"
        px_logger.debug("Forwarding request from "  .. ngx.var.uri .. " to client at " .. px_config.client_host  .. px_request_uri)
        ngx_req_set_uri(px_request_uri)
        px_common_utils.clear_first_party_sensitive_headers(px_config.sensitive_headers);
        _M.forward_to_perimeterx(px_config.client_host, px_config.client_port_overide)
    end

    function _M.reverse_px_xhr()
        if not px_config.first_party_enabled or not px_config.reverse_xhr_enabled then
            if string.match(ngx.var.uri, 'gif') then
                ngx.header["Content-Type"] = 'image/gif';
                ngx.say(ngx.decode_base64(px_constants.EMPTY_GIF_B64))
            else
                ngx.header["Content-Type"] = 'application/json';
                ngx.say('{}')
            end
            ngx.exit(ngx.OK)
            return
        end

        local reverse_prefix = string.sub(px_config.px_appId, 3, string.len(px_config.px_appId))
        local px_request_uri = string.gsub(ngx.var.uri, '/' .. reverse_prefix .. px_constants.FIRST_PARTY_XHR_PATH, '')

        px_logger.debug("Forwarding request from "  .. ngx.var.request_uri .. " to xhr at " .. px_config.collector_host .. px_request_uri)
        ngx_req_set_uri(px_request_uri)

        local vid = ''

        if ngx.var.cookie__pxvid then
            vid = ngx.var.cookie__pxvid
        elseif ngx.var.cookie_pxvid then
            vid = ngx.var.cookie_pxvid
        end

        px_common_utils.clear_first_party_sensitive_headers(px_config.sensitive_headers);

        if vid ~= '' then
            px_logger.debug("Attaching VID cookie" .. vid)
            ngx_req_set_header('cookie', 'pxvid=' .. vid)
        end

        _M.forward_to_perimeterx(px_config.collector_host, px_config.collector_port_overide)
    end

    return _M
end

return M
