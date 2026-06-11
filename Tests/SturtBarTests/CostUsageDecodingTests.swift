import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageDecodingTests {
    @Test
    func `decodes daily report type format`() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "inputTokens": 10,
              "cacheReadTokens": 2,
              "cacheCreationTokens": 3,
              "outputTokens": 20,
              "totalTokens": 30,
              "costUSD": 0.12
            }
          ],
          "summary": {
            "totalInputTokens": 10,
            "totalOutputTokens": 20,
            "cacheReadTokens": 2,
            "cacheCreationTokens": 3,
            "totalTokens": 30,
            "totalCostUSD": 0.12
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].date == "2025-12-20")
        #expect(report.data[0].totalTokens == 30)
        #expect(report.data[0].cacheReadTokens == 2)
        #expect(report.data[0].cacheCreationTokens == 3)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.summary?.totalCostUSD == 0.12)
        #expect(report.summary?.cacheReadTokens == 2)
        #expect(report.summary?.cacheCreationTokens == 3)
    }

    @Test
    func `decodes daily report legacy format`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "2025-12-20",
              "inputTokens": 1,
              "cacheReadTokens": 2,
              "cacheCreationTokens": 3,
              "outputTokens": 2,
              "totalTokens": 3,
              "totalCost": 0.01
            }
          ],
          "totals": {
            "totalInputTokens": 1,
            "totalOutputTokens": 2,
            "cacheReadTokens": 2,
            "cacheCreationTokens": 3,
            "totalTokens": 3,
            "totalCost": 0.01
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.summary?.totalTokens == 3)
        #expect(report.summary?.totalCostUSD == 0.01)
        #expect(report.data[0].cacheReadTokens == 2)
        #expect(report.data[0].cacheCreationTokens == 3)
        #expect(report.summary?.cacheReadTokens == 2)
        #expect(report.summary?.cacheCreationTokens == 3)
    }

    @Test
    func `decodes legacy cache token keys`() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "cacheReadInputTokens": 4,
              "cacheCreationInputTokens": 5,
              "totalTokens": 9
            }
          ],
          "summary": {
            "totalCacheReadTokens": 4,
            "totalCacheCreationTokens": 5,
            "totalTokens": 9
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].cacheReadTokens == 4)
        #expect(report.data[0].cacheCreationTokens == 5)
        #expect(report.summary?.cacheReadTokens == 4)
        #expect(report.summary?.cacheCreationTokens == 5)
    }

    @Test
    func `decodes daily report legacy format with model map`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "inputTokens": 10,
              "outputTokens": 20,
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {
                "claude-sonnet-4-5": {
                  "inputTokens": 10,
                  "outputTokens": 20,
                  "totalTokens": 30
                }
              }
            }
          ],
          "totals": {
            "totalTokens": 30,
            "costUSD": 0.12
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-5"])
    }

    @Test
    func `decodes daily report legacy format with model map sorted`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {
                "z-model": { "totalTokens": 10 },
                "a-model": { "totalTokens": 20 },
                "m-model": { "totalTokens": 0 }
              }
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["a-model", "m-model", "z-model"])
    }

    @Test
    func `decodes daily report legacy format with empty model map as nil`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {}
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == nil)
    }

    @Test
    func `decodes daily report legacy format prefers models used list over models map`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "modelsUsed": ["claude-sonnet-4-5"],
              "models": {
                "ignored-model": { "totalTokens": 30 }
              }
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-5"])
    }

    @Test
    func `decodes daily report legacy format with models list`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": ["claude-sonnet-4-5", "claude-opus-4-5"]
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-5", "claude-opus-4-5"])
    }

    @Test
    func `decodes model breakdown total tokens`() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "totalTokens": 30,
              "costUSD": 0.12,
              "modelBreakdowns": [
                {
                  "modelName": "claude-sonnet-4-5",
                  "costUSD": 0.12,
                  "totalTokens": 30
                }
              ]
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(modelName: "claude-sonnet-4-5", costUSD: 0.12, totalTokens: 30),
        ])
    }

    @Test
    func `decodes daily report legacy format with invalid models field`() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": "claude-sonnet-4"
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == nil)
    }
}
