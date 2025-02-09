import Foundation
import LangChain
import OpenAIService
import Preferences

struct QueryWebsiteFunction: ChatGPTFunction {
    struct Arguments: Codable {
        var query: String
        var urls: [String]
    }

    struct Result: ChatGPTFunctionResult {
        var answers: [String]

        var botReadableContent: String {
            return answers.joined(separator: "\n")
        }
    }

    var reportProgress: (String) async -> Void = { _ in }

    var name: String {
        "queryWebsite"
    }

    var description: String {
        "Useful for when you need to answer a question using information from a website."
    }

    var argumentSchema: JSONSchemaValue {
        return [
            .type: "object",
            .properties: [
                "query": [
                    .type: "string",
                    .description: "things you want to know about the website",
                ],
                "urls": [
                    .type: "array",
                    .description: "urls of the website, you can use urls appearing in the conversation",
                    .items: [
                        .type: "string",
                    ],
                ],
            ],
            .required: ["query", "urls"],
        ]
    }

    func prepare() async {
        await reportProgress("Reading..")
    }

    func call(arguments: Arguments) async throws -> Result {
        do {
            let embedding = OpenAIEmbedding(configuration: UserPreferenceEmbeddingConfiguration())

            let result = try await withThrowingTaskGroup(of: String.self) { group in
                for urlString in arguments.urls {
                    guard let url = URL(string: urlString) else { continue }
                    group.addTask {
                        // 1. grab the website content
                        await reportProgress("Loading \(url)..")
                        
                        if let database = await TemporaryUSearch.view(identifier: urlString) {
                            await reportProgress("Generating answers..")
                            let qa = RetrievalQAChain(vectorStore: database, embedding: embedding) {
                                OpenAIChat(
                                    configuration: UserPreferenceChatGPTConfiguration()
                                        .overriding(.init(temperature: 0)),
                                    stream: true
                                )
                            }
                            return try await qa.call(.init(arguments.query)).answer
                        }
                        let loader = WebLoader(urls: [url])
                        let documents = try await loader.load()
                        await reportProgress("Processing \(url)..")
                        // 2. split the content
                        let splitter = RecursiveCharacterTextSplitter(
                            chunkSize: 1000,
                            chunkOverlap: 100
                        )
                        let splitDocuments = try await splitter.transformDocuments(documents)
                        // 3. embedding and store in db
                        await reportProgress("Embedding \(url)..")
                        let embeddedDocuments = try await embedding.embed(documents: splitDocuments)
                        let database = TemporaryUSearch(identifier: urlString)
                        try await database.set(embeddedDocuments)
                        // 4. generate answer
                        await reportProgress("Generating answers..")
                        let qa = RetrievalQAChain(vectorStore: database, embedding: embedding) {
                            OpenAIChat(
                                configuration: UserPreferenceChatGPTConfiguration()
                                    .overriding(.init(temperature: 0)),
                                stream: true
                            )
                        }
                        let result = try await qa.call(.init(arguments.query))
                        return result.answer
                    }
                }

                var all = [String]()
                for try await result in group {
                    all.append(result)
                }
                await reportProgress("""
                Finish reading websites.
                \(
                    arguments.urls
                        .map { "- [\($0)](\($0))" }
                        .joined(separator: "\n")
                )
                """)
                                     
                return all
            }

            return .init(answers: result)
        } catch {
            await reportProgress("Failed reading websites.")
            throw error
        }
    }
}

