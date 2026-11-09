#include <algorithm>
#include <array>
#include <cwctype>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
    using Version = std::array<unsigned, 3>;

    Version ParseVersion(const std::wstring& text)
    {
        Version result{};
        size_t at = 0;
        for (size_t part = 0; part < result.size(); ++part)
        {
            const size_t start = at;
            while (at < text.size() && text[at] >= L'0' && text[at] <= L'9')
            {
                result[part] = result[part] * 10 + static_cast<unsigned>(text[at++] - L'0');
                if (result[part] > (part == 2 ? 65535u : 255u)) { throw std::runtime_error("MSI version out of range"); }
            }
            if (at == start) { throw std::runtime_error("Missing MSI version component"); }
            if (part != 2 && (at == text.size() || text[at++] != L'.')) { throw std::runtime_error("Invalid MSI version"); }
        }
        if (at != text.size()) { throw std::runtime_error("Invalid MSI version suffix"); }
        return result;
    }

    std::wstring Upper(std::wstring value)
    {
        for (auto& ch : value) { if (ch >= L'a' && ch <= L'z') { ch = static_cast<wchar_t>(ch - L'a' + L'A'); } }
        return value;
    }

    void RejectSameVersionProduct(const std::wstring& installedCode, const std::wstring& installedVersion,
        const std::wstring& candidateCode, const Version& candidateVersion)
    {
        if (Upper(installedCode) != Upper(candidateCode) && ParseVersion(installedVersion) == candidateVersion)
        {
            throw std::runtime_error("A different grate MSI has the same numeric version. Uninstall the installed package explicitly before switching between prerelease or stable packages with that version.");
        }
    }

    struct Instance
    {
        unsigned context;
        std::wstring userSid;
        unsigned state;
        std::wstring publisher;
        std::wstring version;
    };

    bool AcceptLegacy(const std::vector<Instance>& instances, const std::wstring& userSid, const Version& candidate)
    {
        if (instances.empty()) { return false; }
        if (instances.size() != 1) { throw std::runtime_error("Ambiguous legacy MSI contexts"); }
        const auto& item = instances.front();
        if ((item.context != 1 && item.context != 2) || item.userSid != userSid || item.state != 5 || item.publisher != L"erikbra")
        {
            throw std::runtime_error("Legacy MSI identity/context is not the current user's installed grate product");
        }
        if (ParseVersion(item.version) > candidate) { throw std::runtime_error("A newer legacy grate MSI is already installed"); }
        return true;
    }

    std::wstring MergeUpgradeCodes(const std::wstring& existing, const std::vector<std::wstring>& allowed, const std::wstring& legacy)
    {
        std::vector<std::wstring> codes;
        size_t start = 0;
        while (start < existing.size())
        {
            const size_t end = existing.find(L';', start);
            const auto code = Upper(existing.substr(start, end == std::wstring::npos ? end : end - start));
            if (std::find(allowed.begin(), allowed.end(), code) == allowed.end()) { throw std::runtime_error("Unverified product in MSI upgrade action property"); }
            if (std::find(codes.begin(), codes.end(), code) == codes.end()) { codes.push_back(code); }
            if (end == std::wstring::npos) { break; }
            start = end + 1;
        }
        if (!legacy.empty() && std::find(codes.begin(), codes.end(), Upper(legacy)) == codes.end()) { codes.push_back(Upper(legacy)); }
        std::wstring result;
        for (const auto& code : codes) { if (!result.empty()) { result += L';'; } result += code; }
        return result;
    }
}

#if defined(_WIN32) && !defined(GRATE_POLICY_TESTS)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <msi.h>
#include <msiquery.h>
#include <sddl.h>
#include "IdentityContract.h"

namespace
{
    void Check(UINT status, const char* operation)
    {
        if (status != ERROR_SUCCESS) { throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(status)); }
    }

    std::wstring Property(MSIHANDLE session, const wchar_t* name)
    {
        DWORD count = 0;
        wchar_t empty[1]{};
        const UINT first = MsiGetPropertyW(session, name, empty, &count);
        if (first != ERROR_SUCCESS && first != ERROR_MORE_DATA) { Check(first, "MsiGetProperty"); }
        std::wstring value(static_cast<size_t>(count) + 1, L'\0');
        ++count;
        Check(MsiGetPropertyW(session, name, value.data(), &count), "MsiGetProperty");
        value.resize(count);
        return value;
    }

    std::wstring ProductProperty(const wchar_t* code, const std::wstring& sid, MSIINSTALLCONTEXT context, const wchar_t* name)
    {
        DWORD count = 0;
        const UINT first = MsiGetProductInfoExW(code, sid.c_str(), context, name, nullptr, &count);
        if (first != ERROR_SUCCESS && first != ERROR_MORE_DATA) { Check(first, "MsiGetProductInfoEx"); }
        std::wstring value(static_cast<size_t>(count) + 1, L'\0');
        ++count;
        Check(MsiGetProductInfoExW(code, sid.c_str(), context, name, value.data(), &count), "MsiGetProductInfoEx");
        value.resize(count);
        return value;
    }

    std::wstring CallingUserSid()
    {
        HANDLE token = nullptr;
        if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token))
        {
            if (GetLastError() != ERROR_NO_TOKEN || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) { throw std::runtime_error("Cannot inspect installing user's token"); }
        }
        DWORD bytes = 0;
        GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
        std::vector<BYTE> storage(bytes);
        const BOOL obtained = GetTokenInformation(token, TokenUser, storage.data(), bytes, &bytes);
        CloseHandle(token);
        if (!obtained) { throw std::runtime_error("Cannot inspect installing user's SID"); }
        LPWSTR sid = nullptr;
        if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(storage.data())->User.Sid, &sid)) { throw std::runtime_error("Cannot format installing user's SID"); }
        const std::wstring result(sid);
        LocalFree(sid);
        return result;
    }

    std::vector<Instance> CurrentUserInstances(const wchar_t* code, const std::wstring& userSid, const wchar_t* productName = L"grate")
    {
        std::vector<Instance> result;
        for (DWORD index = 0; ; ++index)
        {
            wchar_t installedCode[39]{};
            wchar_t owner[256]{};
            DWORD ownerLength = 256;
            MSIINSTALLCONTEXT context = MSIINSTALLCONTEXT_NONE;
            const UINT status = MsiEnumProductsExW(code, userSid.c_str(), MSIINSTALLCONTEXT_USERMANAGED | MSIINSTALLCONTEXT_USERUNMANAGED,
                index, installedCode, &context, owner, &ownerLength);
            if (status == ERROR_NO_MORE_ITEMS || status == ERROR_UNKNOWN_PRODUCT) { break; }
            Check(status, "MsiEnumProductsEx");
            const auto state = ProductProperty(installedCode, owner, context, INSTALLPROPERTY_PRODUCTSTATE);
            if (state != L"5") { throw std::runtime_error("Related grate MSI is advertised or incompletely installed"); }
            if (ProductProperty(installedCode, owner, context, L"InstalledProductName") != productName) { throw std::runtime_error("Related MSI has an unexpected product name"); }
            result.push_back({ static_cast<unsigned>(context), owner, 5, ProductProperty(installedCode, owner, context, L"Publisher"), ProductProperty(installedCode, owner, context, L"VersionString") });
        }
        return result;
    }

    std::vector<std::wstring> CurrentUserFamily(const wchar_t* family, const std::wstring& sid, const wchar_t* productName)
    {
        std::vector<std::wstring> result;
        for (DWORD index = 0; ; ++index)
        {
            wchar_t code[39]{};
            const UINT status = MsiEnumRelatedProductsW(family, 0, index, code);
            if (status == ERROR_NO_MORE_ITEMS) { break; }
            Check(status, "MsiEnumRelatedProducts");
            const auto instances = CurrentUserInstances(code, sid, productName);
            if (instances.size() > 1) { throw std::runtime_error("Ambiguous new grate MSI contexts"); }
            if (!instances.empty())
            {
                if (instances[0].publisher != L"grate-devs") { throw std::runtime_error("Unexpected publisher in grate upgrade family"); }
                result.push_back(Upper(code));
            }
        }
        return result;
    }

    void Report(MSIHANDLE session, const std::wstring& text, INSTALLMESSAGE kind)
    {
        const MSIHANDLE record = MsiCreateRecord(0);
        if (record)
        {
            MsiRecordSetStringW(record, 0, text.c_str());
            MsiProcessMessage(session, kind, record);
            MsiCloseHandle(record);
        }
    }
}

extern "C" __declspec(dllexport) UINT __stdcall DetectLegacyGrate(MSIHANDLE session)
{
    try
    {
        const auto sid = Property(session, L"UserSID");
        if (sid.empty() || sid == L"S-1-5-18" || sid != CallingUserSid()) { throw std::runtime_error("MSI UserSID does not match the calling user"); }
        const auto version = ParseVersion(Property(session, L"ProductVersion"));
        const auto family = Upper(Property(session, L"UpgradeCode"));
        if (family != GRATE_CURRENT_UPGRADE_CODE) { throw std::runtime_error("Unexpected grate upgrade family for this installer architecture"); }
        if (Property(session, L"ProductName") != GRATE_CURRENT_PRODUCT_NAME ||
            Property(session, L"GRATE_DISTRIBUTION") != GRATE_CURRENT_DISTRIBUTION)
        {
            throw std::runtime_error("Unexpected grate distribution identity for this installer");
        }
        // All variants own the same command and per-user installation directory.
        // Check every other profile/architecture before the transaction changes
        // files, PATH or registration. Only this exact family can major-upgrade.
        for (const auto& other : GRATE_FAMILIES)
        {
            if (family != other.code && !CurrentUserFamily(other.code, sid, other.productName).empty())
            {
                throw std::runtime_error("Another distribution or architecture of grate is already installed for this user; uninstall it explicitly before switching");
            }
        }
        const auto allowed = CurrentUserFamily(family.c_str(), sid, GRATE_CURRENT_PRODUCT_NAME);
        const auto candidateCode = Property(session, L"ProductCode");
        for (const auto& code : allowed)
        {
            const auto instances = CurrentUserInstances(code.c_str(), sid, GRATE_CURRENT_PRODUCT_NAME);
            for (const auto& instance : instances)
            {
                RejectSameVersionProduct(code, instance.version, candidateCode, version);
            }
        }
        const auto legacy = CurrentUserInstances(GRATE_LEGACY_PRODUCT_CODE, sid);
        if (!GRATE_ALLOW_LEGACY && !legacy.empty()) { throw std::runtime_error("Legacy grate is already installed; uninstall it explicitly before switching distribution"); }
        const bool migrate = AcceptLegacy(legacy, sid, version);
        if (migrate) { RejectSameVersionProduct(GRATE_LEGACY_PRODUCT_CODE, legacy.front().version, candidateCode, version); }
        // MajorUpgrade authors a Secure WIX_UPGRADE_DETECTED action property in
        // the Upgrade table. Add only the API-verified current-user legacy code
        // after FindRelatedProducts; standard RemoveExistingProducts consumes it.
        const auto products = MergeUpgradeCodes(Property(session, L"WIX_UPGRADE_DETECTED"), allowed, migrate ? GRATE_LEGACY_PRODUCT_CODE : L"");
        Check(MsiSetPropertyW(session, L"WIX_UPGRADE_DETECTED", products.c_str()), "MsiSetProperty");
        Report(session, migrate ? L"grate: verified current-user legacy MSI added to transactional major upgrade." : L"grate: no current-user legacy MSI to migrate.", INSTALLMESSAGE_INFO);
        return ERROR_SUCCESS;
    }
    catch (const std::exception& error)
    {
        const std::string message(error.what());
        Report(session, L"grate upgrade refused: " + std::wstring(message.begin(), message.end()), INSTALLMESSAGE_ERROR);
        return ERROR_INSTALL_FAILURE;
    }
    catch (...) { Report(session, L"grate upgrade refused: unable to verify existing installation safely.", INSTALLMESSAGE_ERROR); return ERROR_INSTALL_FAILURE; }
}
#endif

#ifdef GRATE_POLICY_TESTS
#include <cassert>
#include <iostream>
int main()
{
    const std::wstring sid = L"S-1-5-21-1-2-3-1000";
    const Version next = ParseVersion(L"2.1.7");
    const auto rejects = [](auto action) { try { action(); } catch (const std::exception&) { return; } throw std::runtime_error("Expected policy rejection"); };
    assert(!AcceptLegacy({}, sid, next));
    Instance old{ 2, sid, 5, L"erikbra", L"2.0.0" };
    assert(AcceptLegacy({ old }, sid, next));
    old.version = L"2.1.6"; assert(AcceptLegacy({ old }, sid, next));
    old.version = L"2.1.8"; rejects([&] { AcceptLegacy({ old }, sid, next); });
    old.version = L"2.1.6"; old.context = 4; rejects([&] { AcceptLegacy({ old }, sid, next); });
    old.context = 2; old.userSid = L"S-1-5-21-1-2-3-1001"; rejects([&] { AcceptLegacy({ old }, sid, next); });
    old.userSid = sid; old.state = 1; rejects([&] { AcceptLegacy({ old }, sid, next); });
    old.state = 5; old.publisher = L"other"; rejects([&] { AcceptLegacy({ old }, sid, next); });
    old.publisher = L"erikbra"; rejects([&] { AcceptLegacy({ old, old }, sid, next); });
    rejects([] { ParseVersion(L"2.1.7.1"); }); rejects([] { ParseVersion(L"2.1.-1"); }); rejects([] { ParseVersion(L"256.1.0"); });
    assert(MergeUpgradeCodes(L"{NEW};{new}", { L"{NEW}" }, L"{OLD}") == L"{NEW};{OLD}");
    rejects([] { MergeUpgradeCodes(L"{FOREIGN}", { L"{NEW}" }, L"{OLD}"); });
    RejectSameVersionProduct(L"{SAME}", L"2.2.0", L"{same}", ParseVersion(L"2.2.0"));
    RejectSameVersionProduct(L"{PREVIOUS}", L"2.1.9", L"{RC}", ParseVersion(L"2.2.0"));
    rejects([] { RejectSameVersionProduct(L"{RC1}", L"2.2.0", L"{RC2}", ParseVersion(L"2.2.0")); });
    rejects([] { RejectSameVersionProduct(L"{RC1}", L"2.2.0", L"{STABLE}", ParseVersion(L"2.2.0")); });
    rejects([] { RejectSameVersionProduct(L"{STABLE}", L"2.2.0", L"{RC1}", ParseVersion(L"2.2.0")); });
    rejects([] { RejectSameVersionProduct(L"{LEGACY}", L"2.1.6", L"{CORRECTED}", ParseVersion(L"2.1.6")); });
    std::cout << "PASS: legacy versions, ownership/context/state, identity, ambiguity and upgrade-list policy.\n";
}
#endif
