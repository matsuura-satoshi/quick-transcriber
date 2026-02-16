import Foundation

/// Solves the assignment problem using the Hungarian algorithm.
/// Given an NxN cost matrix, returns an array where result[i] = column assigned to row i.
public enum HungarianAlgorithm {

    public static func solve(_ costMatrix: [[Int]]) -> [Int] {
        let n = costMatrix.count
        guard n > 0 else { return [] }
        guard costMatrix.allSatisfy({ $0.count == n }) else { return [] }

        let INF = Int.max / 2
        var u = Array(repeating: 0, count: n + 1)
        var v = Array(repeating: 0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: INF, count: n + 1)
            var used = Array(repeating: false, count: n + 1)

            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = INF
                var j1 = 0

                for j in 1...n {
                    if !used[j] {
                        let cur = costMatrix[i0 - 1][j - 1] - u[i0] - v[j]
                        if cur < minv[j] {
                            minv[j] = cur
                            way[j] = j0
                        }
                        if minv[j] < delta {
                            delta = minv[j]
                            j1 = j
                        }
                    }
                }

                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }

                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var result = Array(repeating: 0, count: n)
        for j in 1...n {
            result[p[j] - 1] = j - 1
        }
        return result
    }
}
