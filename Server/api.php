<?php
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

define('DATA_DIR', __DIR__ . '/data');
define('TASKS_FILE', DATA_DIR . '/tasks.json');
define('COMMANDS_FILE', DATA_DIR . '/commands.json');
define('HEARTBEAT_FILE', DATA_DIR . '/heartbeat.json');

if (!is_dir(DATA_DIR)) {
    mkdir(DATA_DIR, 0755, true);
}

// --- 文件锁读写 ---
function read_json($file) {
    if (!file_exists($file)) return [];
    $content = file_get_contents($file);
    return json_decode($content, true) ?: [];
}

function write_json($file, $data) {
    $fp = fopen($file, 'c');
    if (flock($fp, LOCK_EX)) {
        ftruncate($fp, 0);
        fwrite($fp, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        fflush($fp);
        flock($fp, LOCK_UN);
    }
    fclose($fp);
}

function gen_id() {
    return substr(md5(uniqid(mt_rand(), true)), 0, 8);
}

function json_ok($data = []) {
    echo json_encode(array_merge(['code' => 0], $data), JSON_UNESCAPED_UNICODE);
    exit;
}

function json_err($msg, $code = 1) {
    echo json_encode(['code' => $code, 'msg' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 路由 ---
$action = $_GET['action'] ?? '';

switch ($action) {

    // ==================== 前端调用 ====================

    // 创建登录任务
    case 'create_task':
        $tasks = read_json(TASKS_FILE);
        $task_id = gen_id();
        $tasks[$task_id] = [
            'id'         => $task_id,
            'status'     => 'pending',      // pending -> qr_loaded -> scanned -> success / expired
            'qr_image'   => '',             // base64
            'token'      => '',
            'created_at' => time(),
            'updated_at' => time(),
        ];
        write_json(TASKS_FILE, $tasks);

        // 写入命令队列
        $commands = read_json(COMMANDS_FILE);
        $commands[] = [
            'id'      => gen_id(),
            'type'    => 'start_login',
            'task_id' => $task_id,
            'status'  => 'pending',
            'created_at' => time(),
        ];
        write_json(COMMANDS_FILE, $commands);
        json_ok(['task_id' => $task_id]);
        break;

    // 获取所有任务
    case 'get_tasks':
        $tasks = read_json(TASKS_FILE);
        // 检查所有设备在线状态
        $heartbeat = read_json(HEARTBEAT_FILE);
        $devices = [];
        $any_online = false;
        foreach ($heartbeat as $did => $info) {
            $online = (time() - ($info['last_seen'] ?? 0)) < 15;
            $devices[] = [
                'device_id' => $did,
                'online' => $online,
                'last_seen' => $info['last_seen'] ?? 0,
            ];
            if ($online) $any_online = true;
        }
        json_ok([
            'tasks' => array_values($tasks),
            'device_online' => $any_online,
            'devices' => $devices,
        ]);
        break;

    // 前端点击刷新二维码
    case 'refresh_qr':
        $task_id = $_POST['task_id'] ?? '';
        if (!$task_id) json_err('缺少 task_id');
        $tasks = read_json(TASKS_FILE);
        if (!isset($tasks[$task_id])) json_err('任务不存在');
        $tasks[$task_id]['status'] = 'refreshing';
        $tasks[$task_id]['updated_at'] = time();
        write_json(TASKS_FILE, $tasks);

        $commands = read_json(COMMANDS_FILE);
        $commands[] = [
            'id'      => gen_id(),
            'type'    => 'refresh',
            'task_id' => $task_id,
            'status'  => 'pending',
            'created_at' => time(),
        ];
        write_json(COMMANDS_FILE, $commands);
        json_ok();
        break;

    // 前端删除任务
    case 'delete_task':
        $task_id = $_POST['task_id'] ?? '';
        if (!$task_id) json_err('缺少 task_id');
        $tasks = read_json(TASKS_FILE);
        if (isset($tasks[$task_id])) {
            // 发送关闭命令
            $commands = read_json(COMMANDS_FILE);
            $commands[] = [
                'id'      => gen_id(),
                'type'    => 'dismiss',
                'task_id' => $task_id,
                'status'  => 'pending',
                'created_at' => time(),
            ];
            write_json(COMMANDS_FILE, $commands);
            unset($tasks[$task_id]);
            write_json(TASKS_FILE, $tasks);
        }
        json_ok();
        break;

    // ==================== Tweak 调用 ====================

    // Tweak 心跳 + 拉取命令
    case 'get_command':
        $device_id = $_GET['device_id'] ?? 'default';
        // 更新心跳（按设备 ID 分开存储）
        $heartbeat = read_json(HEARTBEAT_FILE);
        $heartbeat[$device_id] = [
            'last_seen' => time(),
        ];
        write_json(HEARTBEAT_FILE, $heartbeat);
        // 取出未执行的命令
        $commands = read_json(COMMANDS_FILE);
        $pending = [];
        foreach ($commands as &$cmd) {
            if ($cmd['status'] === 'pending') {
                $pending[] = $cmd;
                $cmd['status'] = 'sent';
            }
        }
        write_json(COMMANDS_FILE, $commands);
        // 清理超过 5 分钟的旧命令
        $commands = array_filter($commands, function($c) {
            return (time() - $c['created_at']) < 300;
        });
        write_json(COMMANDS_FILE, array_values($commands));
        json_ok(['commands' => $pending]);
        break;

    // Tweak 上传二维码图片
    case 'upload_qr':
        $input = json_decode(file_get_contents('php://input'), true);
        $task_id = $input['task_id'] ?? '';
        $qr_image = $input['qr_image'] ?? '';
        $token = $input['token'] ?? '';
        if (!$task_id || !$qr_image) json_err('缺少参数');

        $tasks = read_json(TASKS_FILE);
        if (!isset($tasks[$task_id])) json_err('任务不存在');
        $tasks[$task_id]['qr_image'] = $qr_image;
        $tasks[$task_id]['token'] = $token;
        $tasks[$task_id]['status'] = 'qr_loaded';
        $tasks[$task_id]['updated_at'] = time();
        write_json(TASKS_FILE, $tasks);
        json_ok();
        break;

    // Tweak 上报状态变化
    case 'update_status':
        $input = json_decode(file_get_contents('php://input'), true);
        $task_id = $input['task_id'] ?? '';
        $status = $input['status'] ?? '';
        if (!$task_id || !$status) json_err('缺少参数');

        $tasks = read_json(TASKS_FILE);
        if (!isset($tasks[$task_id])) json_err('任务不存在');
        $tasks[$task_id]['status'] = $status;
        $tasks[$task_id]['updated_at'] = time();
        // 如果有新的二维码图片（刷新后）
        if (!empty($input['qr_image'])) {
            $tasks[$task_id]['qr_image'] = $input['qr_image'];
        }
        write_json(TASKS_FILE, $tasks);
        json_ok();
        break;

    // Tweak 确认命令已执行
    case 'ack_command':
        $input = json_decode(file_get_contents('php://input'), true);
        $cmd_id = $input['command_id'] ?? '';
        if (!$cmd_id) json_err('缺少 command_id');
        $commands = read_json(COMMANDS_FILE);
        foreach ($commands as &$cmd) {
            if ($cmd['id'] === $cmd_id) {
                $cmd['status'] = 'done';
            }
        }
        write_json(COMMANDS_FILE, $commands);
        json_ok();
        break;

    default:
        json_err('未知 action: ' . $action);
}
