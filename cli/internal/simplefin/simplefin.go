// Package simplefin is the minimal SimpleFIN protocol client (mirrors
// SimpleFINClient.swift). Two operations: claim a setup token for an access URL,
// and fetch accounts + transactions. This is the ONLY network code for banking.
//
// Spec: https://www.simplefin.org/protocol.html
package simplefin

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/RomneyDa/phinny/cli/internal/model"
)

// FetchResult is the mapped result of a fetch.
type FetchResult struct {
	Accounts     []model.Account
	Transactions []model.Transaction
}

var client = &http.Client{Timeout: 60 * time.Second}

// Claim exchanges a single-use base64 setup token for a permanent access URL.
func Claim(setupToken string) (string, error) {
	token := strings.TrimSpace(setupToken)
	claimURL, err := decodeClaimURL(token)
	if err != nil {
		return "", fmt.Errorf("that doesn't look like a valid SimpleFIN setup token")
	}
	req, err := http.NewRequest(http.MethodPost, claimURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Length", "0")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("claiming the setup token failed (HTTP %d). Tokens are single-use - you may need a fresh one", resp.StatusCode)
	}
	accessURL := strings.TrimSpace(string(body))
	if !strings.HasPrefix(accessURL, "http") {
		return "", fmt.Errorf("claiming the setup token failed (HTTP %d)", resp.StatusCode)
	}
	return accessURL, nil
}

func decodeClaimURL(token string) (string, error) {
	b64 := token
	if r := len(b64) % 4; r > 0 {
		b64 += strings.Repeat("=", 4-r)
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	s := strings.TrimSpace(string(data))
	u, err := url.Parse(s)
	if err != nil || !strings.HasPrefix(strings.ToLower(u.Scheme), "http") {
		return "", fmt.Errorf("bad claim url")
	}
	return s, nil
}

// Fetch pulls accounts + transactions posted since `since`. RATE-LIMITED.
func Fetch(accessURL string, since time.Time) (FetchResult, error) {
	u, err := url.Parse(accessURL)
	if err != nil {
		return FetchResult{}, fmt.Errorf("the stored SimpleFIN access URL is malformed")
	}
	// SimpleFIN embeds basic-auth credentials in the URL userinfo.
	var username, password string
	if u.User != nil {
		username = u.User.Username()
		password, _ = u.User.Password()
	}
	u.User = nil
	u.Path = strings.TrimRight(u.Path, "/") + "/accounts"
	q := u.Query()
	q.Set("start-date", strconv.FormatInt(since.Unix(), 10))
	q.Set("pending", "1")
	u.RawQuery = q.Encode()

	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return FetchResult{}, err
	}
	if username != "" {
		creds := username + ":" + password
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(creds)))
	}
	resp, err := client.Do(req)
	if err != nil {
		return FetchResult{}, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return FetchResult{}, fmt.Errorf("SimpleFIN request failed (HTTP %d)", resp.StatusCode)
	}

	var payload setResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return FetchResult{}, fmt.Errorf("could not read the SimpleFIN response: %v", err)
	}
	return mapPayload(payload), nil
}

func mapPayload(p setResponse) FetchResult {
	var res FetchResult
	for _, raw := range p.Accounts {
		org := ""
		if raw.Org != nil {
			if raw.Org.Name != "" {
				org = raw.Org.Name
			} else {
				org = raw.Org.Domain
			}
		}
		currency := raw.Currency
		if currency == "" {
			currency = "USD"
		}
		acct := model.Account{
			ID: raw.ID, Name: raw.Name, OrgName: org, Currency: currency,
			Balance: parseFloat(raw.Balance),
		}
		if raw.AvailableBalance != "" {
			v := parseFloat(raw.AvailableBalance)
			acct.AvailableBalance = &v
		}
		if raw.BalanceDate != nil {
			acct.BalanceDate = raw.BalanceDate
		}
		res.Accounts = append(res.Accounts, acct)

		for _, t := range raw.Transactions {
			posted := t.Posted
			if posted == 0 && t.TransactedAt != nil {
				posted = *t.TransactedAt
			}
			txn := model.Transaction{
				ID:          raw.ID + "|" + t.ID,
				ProviderID:  t.ID,
				AccountID:   raw.ID,
				Posted:      posted,
				Amount:      parseFloat(t.Amount),
				Description: t.Description,
				Pending:     t.Pending,
			}
			if t.Payee != "" {
				txn.Payee = &t.Payee
			}
			if t.Memo != "" {
				txn.Memo = &t.Memo
			}
			if cat, ok := t.Extra["category"]; ok {
				if s, ok := cat.(string); ok && s != "" {
					txn.Category = &s
				}
			}
			res.Transactions = append(res.Transactions, txn)
		}
	}
	return res
}

func parseFloat(s string) float64 {
	v, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return v
}

// ---- wire format (amounts are decimal strings) --------------------------

type setResponse struct {
	Accounts []rawAccount `json:"accounts"`
}

type rawAccount struct {
	ID               string          `json:"id"`
	Name             string          `json:"name"`
	Currency         string          `json:"currency"`
	Balance          string          `json:"balance"`
	AvailableBalance string          `json:"available-balance"`
	BalanceDate      *int64          `json:"balance-date"`
	Org              *rawOrg         `json:"org"`
	Transactions     []rawTransaction `json:"transactions"`
}

type rawOrg struct {
	Name   string `json:"name"`
	Domain string `json:"domain"`
}

type rawTransaction struct {
	ID           string         `json:"id"`
	Posted       int64          `json:"posted"`
	TransactedAt *int64         `json:"transacted_at"`
	Amount       string         `json:"amount"`
	Description  string         `json:"description"`
	Payee        string         `json:"payee"`
	Memo         string         `json:"memo"`
	Pending      bool           `json:"pending"`
	Extra        map[string]any `json:"extra"`
}
