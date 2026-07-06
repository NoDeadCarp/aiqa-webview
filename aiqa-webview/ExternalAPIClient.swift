import Foundation

/// 一个非常轻量的 API 客户端。
///
/// 之所以单独拆成文件，是为了把“浏览器页面逻辑”和“HTTP 请求逻辑”分开：
/// - `BrowserViewModel` 负责控制流程
/// - `ExternalAPIClient` 负责把数据发给外部接口
struct ExternalAPIClient {
    /// 当前用户给出的接口地址。
    private let endpointURL = URL(string: "https://aiqa.nuit-v6.stzze.cn/api/match-web")!

    /// 使用系统自带的 URLSession 即可，简单易学。
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 把抓取出来的题目文本 POST 给外部接口。
    ///
    /// 当前接口约定：
    /// ```json
    /// { "question": "...JS 提取结果..." }
    /// ```
    func sendQuestion(_ question: String) async throws -> MatchWebDisplayResult {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(question: question))

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExternalAPIError.invalidResponse
        }

        let responseText = data.isEmpty ? "" : String(decoding: data, as: UTF8.self)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw ExternalAPIError.serverError(
                statusCode: httpResponse.statusCode,
                responseText: responseText
            )
        }

        return formatDisplayResult(from: data, fallbackText: responseText)
    }
}

private extension ExternalAPIClient {
    struct RequestBody: Encodable {
        let question: String
    }

    enum ExternalAPIError: LocalizedError {
        case invalidResponse
        case serverError(statusCode: Int, responseText: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "接口没有返回有效的 HTTP 响应。"
            case let .serverError(statusCode, responseText):
                if responseText.isEmpty {
                    return "接口返回了错误状态码：\(statusCode)。"
                }

                return "接口返回了错误状态码：\(statusCode)。响应内容：\(responseText)"
            }
        }
    }

    /// 把接口 JSON 整理成更适合用户阅读的结构，并保留原始返回用于调试。
    func formatDisplayResult(from data: Data, fallbackText: String) -> MatchWebDisplayResult {
        let rawResponse = fallbackText.isEmpty ? "接口返回成功，但响应体为空。" : fallbackText

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MatchWebDisplayResult(
                title: "API 返回结果",
                isSuccess: nil,
                statusText: "已收到返回，但不是标准 JSON 格式。",
                matchedQuestion: nil,
                questionType: nil,
                similarity: nil,
                answerLabel: nil,
                displayedAnswer: nil,
                rawResponse: rawResponse
            )
        }

        let successValue = intValue(jsonObject["success"])
        let matchedQuestion = nonEmptyStringValue(jsonObject["matched_question"])
        let answer = nonEmptyStringValue(jsonObject["answer"])
        let similarity = nonEmptyStringValue(jsonObject["similarity"])
        let questionType = nonEmptyStringValue(jsonObject["question_type"])
        let remappedAnswer = nonEmptyStringValue(jsonObject["remapped_answer"])

        let displayedAnswer = remappedAnswer ?? answer
        let answerLabel = remappedAnswer == nil ? (answer == nil ? nil : "答案") : "乱序答案"

        let title: String
        let isSuccess: Bool?
        let statusText: String
        switch successValue {
        case 1:
            title = "匹配成功"
            isSuccess = true
            statusText = "已成功匹配到题目结果。"
        case 0:
            title = "匹配失败"
            isSuccess = false
            statusText = "这次没有匹配到有效结果。"
        default:
            title = "API 返回结果"
            isSuccess = nil
            statusText = "接口已返回结果，但 success 字段不是标准的 0 / 1。"
        }

        return MatchWebDisplayResult(
            title: title,
            isSuccess: isSuccess,
            statusText: statusText,
            matchedQuestion: matchedQuestion,
            questionType: questionType,
            similarity: similarity,
            answerLabel: answerLabel,
            displayedAnswer: displayedAnswer,
            rawResponse: rawResponse
        )
    }

    func nonEmptyStringValue(_ value: Any?) -> String? {
        let text = stringValue(value)
        return text.isEmpty ? nil : text
    }

    /// 把接口字段尽量转成字符串，兼容字符串 / 数字 / 布尔值返回。
    func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return ""
        }
    }

    func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

struct MatchWebDisplayResult {
    let title: String
    let isSuccess: Bool?
    let statusText: String
    let matchedQuestion: String?
    let questionType: String?
    let similarity: String?
    let answerLabel: String?
    let displayedAnswer: String?
    let rawResponse: String
}
